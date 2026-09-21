import Foundation
import UserNotifications

public final class NotificationsCapability: Capability, @unchecked Sendable {
    public let name = "notifications"

    private let center = UNUserNotificationCenter.current()

    public init() {}

    public func permissionStatus() async -> PermissionStatus {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:        return .notDetermined
        case .denied:               return .denied
        case .authorized, .provisional, .ephemeral: return .granted
        @unknown default:           return .notDetermined
        }
    }

    public func requestPermission() async -> PermissionStatus {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            return granted ? .granted : .denied
        } catch {
            return .denied
        }
    }

    public func invoke(method: String, params: CapabilityParams) async throws -> CapabilityResult {
        let isRemoval = method == "cancel" || method == "cancelCron" || method == "clearCronReminders"
        if !isRemoval,
           await permissionStatus() != .granted,
           await requestPermission() != .granted {
            throw CapabilityError.permissionDenied
        }
        switch method {
        case "schedule":
            guard let title = params["title"]?.stringValue else { throw CapabilityError.missingParam("title") }
            let body = params["body"]?.stringValue ?? ""
            let delay = params["delaySeconds"]?.intValue ?? 0

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default

            let trigger: UNNotificationTrigger? = delay > 0
                ? UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(delay), repeats: false)
                : nil

            let id = UUID().uuidString
            let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
            try await center.add(request)
            return .object(["id": .string(id)])
        case "scheduleCron":
            guard let jobID = params["jobId"]?.stringValue else { throw CapabilityError.missingParam("jobId") }
            guard let schedule = params["schedule"]?.stringValue else { throw CapabilityError.missingParam("schedule") }
            let jobName = params["name"]?.stringValue ?? "Tâche Hermes"
            let ids = try await scheduleCronReminder(jobID: jobID, name: jobName, schedule: schedule)
            return .object([
                "scheduled": .bool(!ids.isEmpty),
                "ids": .array(ids.map(AnyCodable.string)),
            ])
        case "cancelCron":
            guard let jobID = params["jobId"]?.stringValue else { throw CapabilityError.missingParam("jobId") }
            await removeCronReminders(jobID: jobID)
            return .null
        case "clearCronReminders":
            await removeCronReminders(jobID: nil)
            return .null
        case "cancel":
            guard let id = params["id"]?.stringValue else { throw CapabilityError.missingParam("id") }
            center.removePendingNotificationRequests(withIdentifiers: [id])
            return .null
        default:
            throw CapabilityError.unknownMethod(method)
        }
    }

    // MARK: - Hermes scheduled-task reminders

    /// Registers an iOS-owned reminder. Once it is accepted by
    /// UNUserNotificationCenter it remains available even if WebKit and the app are
    /// suspended, which is exactly when WebUI polling can no longer run on iOS.
    private func scheduleCronReminder(jobID: String, name: String, schedule: String) async throws -> [String] {
        await removeCronReminders(jobID: jobID)
        let parsed = Self.notificationTriggers(for: schedule)
        guard !parsed.isEmpty else {
            throw CapabilityError.underlying("Unsupported Hermes schedule: \(schedule)")
        }

        let content = UNMutableNotificationContent()
        content.title = "Hermex · \(name)"
        content.body = "La tâche planifiée démarre maintenant. Ouvre Hermex pour consulter le résultat."
        content.sound = .default
        content.userInfo = ["hermesJobID": jobID]

        var ids: [String] = []
        for (index, trigger) in parsed.enumerated() {
            let identifier = Self.cronIdentifier(jobID: jobID, index: index)
            try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
            ids.append(identifier)
        }
        return ids
    }

    private func removeCronReminders(jobID: String?) async {
        let prefix = jobID.map { Self.cronIdentifierPrefix + Self.safeIdentifierPart($0) + "." }
            ?? Self.cronIdentifierPrefix
        let pending = await center.pendingNotificationRequests()
        let ids = pending.map(\.identifier).filter { $0.hasPrefix(prefix) }
        if !ids.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    private static let cronIdentifierPrefix = "hermex.cron."

    private static func cronIdentifier(jobID: String, index: Int) -> String {
        cronIdentifierPrefix + safeIdentifierPart(jobID) + ".\(index)"
    }

    private static func safeIdentifierPart(_ value: String) -> String {
        String(value.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" })
    }

    private static func notificationTriggers(for rawSchedule: String) -> [UNNotificationTrigger] {
        let schedule = rawSchedule.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !schedule.isEmpty else { return [] }

        // One-shot ISO timestamp returned by Hermes for canonical one-shot jobs.
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: rawSchedule), date.timeIntervalSinceNow > 1 {
            return [UNTimeIntervalNotificationTrigger(timeInterval: date.timeIntervalSinceNow, repeats: false)]
        }

        if let parts = captures(#"^in\s+(\d+)\s*(s|sec|secs|second|seconds|m|min|mins|minute|minutes|h|hr|hrs|hour|hours)$"#, in: schedule),
           let value = Int(parts[0]) {
            return [UNTimeIntervalNotificationTrigger(timeInterval: max(1, interval(value: value, unit: parts[1])), repeats: false)]
        }
        if let parts = captures(#"^(\d+)\s*(s|m|h)$"#, in: schedule), let value = Int(parts[0]) {
            return [UNTimeIntervalNotificationTrigger(timeInterval: max(1, interval(value: value, unit: parts[1])), repeats: false)]
        }
        if let parts = captures(#"^every\s+(\d+)\s*(m|min|mins|minute|minutes|h|hr|hrs|hour|hours)$"#, in: schedule),
           let value = Int(parts[0]) {
            return [UNTimeIntervalNotificationTrigger(timeInterval: max(60, interval(value: value, unit: parts[1])), repeats: true)]
        }

        if schedule == "@hourly" {
            return [UNCalendarNotificationTrigger(dateMatching: DateComponents(minute: 0), repeats: true)]
        }
        if schedule == "@daily" {
            return [calendarTrigger(hour: 9, minute: 0)]
        }

        // Standard five-field cron forms generated by the WebUI presets.
        let fields = schedule.split(whereSeparator: \.isWhitespace).map(String.init)
        if fields.count == 5,
           let minute = Int(fields[0]), (0...59).contains(minute),
           let hour = Int(fields[1]), (0...23).contains(hour),
           fields[2] == "*", fields[3] == "*" {
            if fields[4] == "*" {
                return [calendarTrigger(hour: hour, minute: minute)]
            }
            if fields[4] == "1-5" {
                return (2...6).map { weekday in
                    UNCalendarNotificationTrigger(
                        dateMatching: DateComponents(hour: hour, minute: minute, weekday: weekday),
                        repeats: true
                    )
                }
            }
            if let cronWeekday = Int(fields[4]), (0...6).contains(cronWeekday) {
                return [UNCalendarNotificationTrigger(
                    dateMatching: DateComponents(hour: hour, minute: minute, weekday: cronWeekday + 1),
                    repeats: true
                )]
            }
        }

        if let parts = captures(#"^(?:every day|daily)\s+at\s+(.+)$"#, in: schedule),
           let time = parseTime(parts[0]) {
            return [calendarTrigger(hour: time.hour, minute: time.minute)]
        }
        if let parts = captures(#"^weekdays\s+at\s+(.+)$"#, in: schedule),
           let time = parseTime(parts[0]) {
            return (2...6).map { weekday in
                UNCalendarNotificationTrigger(
                    dateMatching: DateComponents(hour: time.hour, minute: time.minute, weekday: weekday),
                    repeats: true
                )
            }
        }
        if let parts = captures(#"^every\s+(sunday|monday|tuesday|wednesday|thursday|friday|saturday)\s+(?:at\s+)?(.+)$"#, in: schedule),
           let weekday = weekdayNumber(parts[0]), let time = parseTime(parts[1]) {
            return [UNCalendarNotificationTrigger(
                dateMatching: DateComponents(hour: time.hour, minute: time.minute, weekday: weekday),
                repeats: true
            )]
        }
        return []
    }

    private static func calendarTrigger(hour: Int, minute: Int) -> UNNotificationTrigger {
        UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: hour, minute: minute), repeats: true)
    }

    private static func interval(value: Int, unit: String) -> TimeInterval {
        if unit.hasPrefix("h") { return TimeInterval(value * 3600) }
        if unit.hasPrefix("m") { return TimeInterval(value * 60) }
        return TimeInterval(value)
    }

    private static func parseTime(_ raw: String) -> (hour: Int, minute: Int)? {
        guard let parts = captures(#"^(\d{1,2})(?::(\d{2}))?\s*(am|pm)?$"#, in: raw),
              var hour = Int(parts[0]) else { return nil }
        let minute = Int(parts[1].isEmpty ? "0" : parts[1]) ?? -1
        let suffix = parts[2]
        guard (0...59).contains(minute) else { return nil }
        if suffix == "am" || suffix == "pm" {
            guard (1...12).contains(hour) else { return nil }
            if suffix == "am" && hour == 12 { hour = 0 }
            if suffix == "pm" && hour != 12 { hour += 12 }
        }
        guard (0...23).contains(hour) else { return nil }
        return (hour, minute)
    }

    private static func weekdayNumber(_ name: String) -> Int? {
        ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
            .firstIndex(of: name).map { $0 + 1 }
    }

    private static func captures(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.range.location != NSNotFound else { return nil }
        return (1..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return "" }
            return String(text[swiftRange])
        }
    }
}
