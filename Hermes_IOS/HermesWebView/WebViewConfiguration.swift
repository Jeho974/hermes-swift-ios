import Foundation
import WebKit

public enum WebViewConfiguration {

    /// Build the canonical `WKWebViewConfiguration` for the app web container.
    /// Registers exactly ONE script message handler: `"hermes"`. Do not add more — route everything
    /// through that single handler so the protocol stays a one-channel contract with the web client.
    public static func make(bridge: JSBridge, bridgeEnabled: Bool) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        let userContent = WKUserContentController()

        if bridgeEnabled {
            // Single script message handler — all JS → native traffic flows through this.
            userContent.add(bridge, name: "hermes")

            // Inject the bridge stub so the web client can call window.hermes.invoke(...)
            // before any of its own scripts run.
            let stub = """
        (function() {
          if (window.hermes) return;
          const pending = new Map();
          let nextId = 1;

          window.hermes = {
            invoke(method, params) {
              return new Promise((resolve, reject) => {
                const id = "h-" + (nextId++);
                pending.set(id, { resolve, reject });
                window.webkit.messageHandlers.hermes.postMessage({ id, method, params: params || null });
              });
            },
            deliverResponse({ id, result, error }) {
              const p = pending.get(id);
              if (!p) return;
              pending.delete(id);
              if (error) reject(p, error); else resolve(p, result);
            }
          };

          function resolve(p, v) { p.resolve(v); }
          function reject(p, e) { p.reject(e); }
        })();
        """
            let userScript = WKUserScript(source: stub, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            userContent.addUserScript(userScript)

            // iOS WKWebView speech-recognition shim:
            // expose a SpeechRecognition-like surface backed by native capability.speechRecognition.transcribeOnce.
            // This gives webui a reliable STT path when browser speech APIs are missing/partial on iPhone.
            let speechShim = """
        (function() {
          if (window.SpeechRecognition || window.webkitSpeechRecognition) return;
          if (!window.hermes || typeof window.hermes.invoke !== "function") return;

          class HermesSpeechRecognition {
            constructor() {
              this.lang = (navigator.language || "en-US");
              this.continuous = false;
              this.onstart = null;
              this.onresult = null;
              this.onerror = null;
              this.onend = null;
              this._active = false;
            }

            start() {
              if (this._active) return;
              this._active = true;
              this._emit(this.onstart, { type: "start" });

              const runOnce = async () => {
                try {
                  const result = await window.hermes.invoke("capability.speechRecognition.transcribeOnce", {
                    locale: this.lang || "en-US",
                    timeoutSeconds: 8
                  });
                  if (!this._active) return;
                  const text = (result && result.text) ? String(result.text) : "";
                  if (text) {
                    const event = this._makeResultEvent(text);
                    this._emit(this.onresult, event);
                  } else {
                    this._emit(this.onerror, { type: "error", error: "no-speech" });
                  }
                } catch (e) {
                  if (!this._active) return;
                  this._emit(this.onerror, { type: "error", error: "network", message: String(e || "speech error") });
                }
              };

              const loop = async () => {
                while (this._active) {
                  await runOnce();
                  if (!this.continuous) break;
                }
                if (this._active) this.stop();
              };
              loop();
            }

            stop() {
              if (!this._active) return;
              this._active = false;
              try {
                window.hermes.invoke("capability.speechRecognition.stop", {});
              } catch (_) {}
              this._emit(this.onend, { type: "end" });
            }

            abort() {
              this.stop();
            }

            _emit(handler, event) {
              if (typeof handler === "function") {
                try { handler(event); } catch (_) {}
              }
            }

            _makeResultEvent(text) {
              const alt = { transcript: text, confidence: 1 };
              const res = { 0: alt, isFinal: true, length: 1 };
              return {
                type: "result",
                resultIndex: 0,
                results: { 0: res, length: 1 }
              };
            }
          }

          window.SpeechRecognition = HermesSpeechRecognition;
          window.webkitSpeechRecognition = HermesSpeechRecognition;
        })();
        """
            let speechShimScript = WKUserScript(source: speechShim, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            userContent.addUserScript(speechShimScript)

            // Hermes WebUI intentionally stops polling cron completions while the
            // document is hidden. iOS then suspends WKWebView, so a server-side job
            // cannot create a notification after the app is closed. Mirror the
            // task's schedule into UNUserNotificationCenter while the app is open;
            // the local reminder is then owned and delivered by iOS.
            let cronReminderShim = #"""
        (function installHermexCronReminders() {
          if (window.__hermexCronReminderInstaller) return;
          window.__hermexCronReminderInstaller = true;

          const invoke = (method, params) => {
            if (!window.hermes || typeof window.hermes.invoke !== "function") return Promise.resolve();
            return window.hermes.invoke(method, params || {}).catch(() => {});
          };
          const scheduleText = (job) => {
            if (!job) return "";
            if (typeof job.schedule === "string") return job.schedule;
            if (job.schedule && typeof job.schedule === "object") {
              return job.schedule.run_at || job.schedule.expr || job.schedule.expression || job.schedule_display || "";
            }
            return job.schedule_display || "";
          };
          const register = (job) => {
            if (!job || job.enabled === false || job.toast_notifications === false || !job.id) return Promise.resolve();
            const schedule = scheduleText(job);
            if (!schedule) return Promise.resolve();
            return invoke("capability.notifications.scheduleCron", {
              jobId: String(job.id),
              name: String(job.name || "Tâche Hermes"),
              schedule: String(schedule)
            });
          };
          const parseBody = (options) => {
            try { return options && options.body ? JSON.parse(options.body) : {}; }
            catch (_) { return {}; }
          };

          const install = () => {
            if (typeof window.api !== "function") { setTimeout(install, 250); return; }
            if (window.api.__hermexCronWrapped) return;
            const original = window.api;
            const wrapped = async function(path, options) {
              const result = await original.apply(this, arguments);
              try {
                const body = parseBody(options);
                if (path === "/api/crons/create" && body.toast_notifications !== false) {
                  const job = (result && result.job) || Object.assign({}, body, {id: result && result.id});
                  await register(job);
                } else if (path === "/api/crons/update" && body.job_id) {
                  if (body.toast_notifications === false) {
                    await invoke("capability.notifications.cancelCron", {jobId: String(body.job_id)});
                  } else {
                    const refreshed = await original("/api/crons");
                    const job = (refreshed.jobs || []).find(j => String(j.id) === String(body.job_id));
                    if (job) await register(job);
                  }
                } else if (path === "/api/crons/delete" && body.job_id) {
                  await invoke("capability.notifications.cancelCron", {jobId: String(body.job_id)});
                }
              } catch (_) {}
              return result;
            };
            Object.assign(wrapped, original);
            wrapped.__hermexCronWrapped = true;
            window.api = wrapped;

            // Reconcile existing tasks on each app launch. This also covers tasks
            // that Hermes created from chat or another client while this app was closed.
            setTimeout(async () => {
              try {
                const data = await original("/api/crons");
                await invoke("capability.notifications.clearCronReminders", {});
                for (const job of (data.jobs || [])) await register(job);
              } catch (_) {}
            }, 1000);
          };
          install();
        })();
        """#
            userContent.addUserScript(WKUserScript(
                source: cronReminderShim,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            ))
        }

        config.userContentController = userContent
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        if #available(iOS 16.4, *) {
            config.preferences.isElementFullscreenEnabled = true
        }
        config.websiteDataStore = .default()
        return config
    }
}
