import Foundation
@preconcurrency import UserNotifications

/// Local notifications for due local tasks. Reminder-backed items are notified by Reminders itself.
@MainActor
final class TodoNotifier: NSObject, UNUserNotificationCenterDelegate {
    enum Status: Equatable { case unknown, notDetermined, authorized, denied }

    nonisolated static let prefix = "sidestats.todo."
    /// macOS keeps at most 64 pending requests per app.
    private nonisolated static let limit = 60

    var onStatus: ((Status) -> Void)?
    private var didSetDelegate = false

    /// `UNUserNotificationCenter.current()` raises outside an app bundle (e.g. `swift run`).
    static var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    /// When local reminders fire. All-day tasks fire at 9:00 on their day.
    nonisolated static func fireDate(_ t: TodoItem) -> Date? {
        guard let due = t.due else { return nil }
        return t.allDay ? Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: due) : due
    }

    nonisolated static func wanted(_ items: [TodoItem], now: Date = Date()) -> [TodoItem] {
        items.filter { !$0.done && !$0.isReminder && (fireDate($0).map { $0 > now } ?? false) }
            .sorted { fireDate($0)! < fireDate($1)! }
            .prefix(limit).map { $0 }
    }

    func refreshStatus() {
        guard Self.available else { return }
        UNUserNotificationCenter.current().getNotificationSettings { s in
            let st = Self.status(s.authorizationStatus)
            DispatchQueue.main.async { self.onStatus?(st) }
        }
    }

    /// Makes pending notifications match `items`. `prompt` asks for permission if not decided yet
    /// (only when something actually needs scheduling, unless `force`).
    func sync(_ items: [TodoItem], enabled: Bool, prompt: Bool, force: Bool = false) {
        guard Self.available else { return }
        let center = UNUserNotificationCenter.current()
        if !didSetDelegate { center.delegate = self; didSetDelegate = true }
        let wanted = enabled ? Self.wanted(items) : []
        center.getNotificationSettings { s in
            let status = s.authorizationStatus
            DispatchQueue.main.async {
                self.onStatus?(Self.status(status))
                switch status {
                case .authorized, .provisional:
                    self.schedule(wanted)
                case .notDetermined where prompt && (force || !wanted.isEmpty):
                    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                        DispatchQueue.main.async {
                            self.onStatus?(granted ? .authorized : .denied)
                            if granted { self.schedule(wanted) }
                        }
                    }
                default:
                    if wanted.isEmpty { self.schedule([]) }
                }
            }
        }
    }

    private func schedule(_ wanted: [TodoItem]) {
        let center = UNUserNotificationCenter.current()
        let ids = Set(wanted.map { Self.prefix + $0.id })
        center.getPendingNotificationRequests { pending in
            let stale = pending.map(\.identifier).filter { $0.hasPrefix(Self.prefix) && !ids.contains($0) }
            if !stale.isEmpty { UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: stale) }
        }
        for t in wanted {
            guard let fire = Self.fireDate(t) else { continue }
            let content = UNMutableNotificationContent()
            content.title = t.title
            content.body = t.notes.isEmpty ? (t.allDay ? "Due today" : "Due now") : t.notes
            content.sound = .default
            content.threadIdentifier = "sidestats.tasks"
            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            // Re-adding the same identifier replaces the previous request.
            center.add(UNNotificationRequest(identifier: Self.prefix + t.id, content: content, trigger: trigger))
        }
    }

    private nonisolated static func status(_ s: UNAuthorizationStatus) -> Status {
        switch s {
        case .authorized, .provisional, .ephemeral: return .authorized
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .unknown
        }
    }

    // Show banners even while SideStats (e.g. its Settings window) is frontmost.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
}
