import CoreGraphics
import EventKit
import Foundation

/// Thin EventKit bridge for Apple Reminders. Converts reminders to `TodoItem`s and writes changes back.
@MainActor
final class TodoReminders {
    private let store = EKEventStore()
    private var observer: Any?

    static var access: RemindersAccess {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: return .full
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        case .writeOnly: return .writeOnly
        @unknown default: return .denied
        }
    }

    /// Requesting access without a usage description in Info.plist crashes the process
    /// (e.g. when run via `swift run` outside the app bundle).
    static var canRequest: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSRemindersFullAccessUsageDescription") != nil
    }

    func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToReminders()) ?? false
    }

    func start(onChange: @escaping @MainActor () -> Void) {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { _ in
            MainActor.assumeIsolated { onChange() }
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    func lists() -> [ReminderList] {
        store.calendars(for: .reminder)
            .map { ReminderList(id: $0.calendarIdentifier, title: $0.title, color: Self.hex($0.cgColor),
                                source: $0.source?.title ?? "", writable: $0.allowsContentModifications) }
            .sorted { ($0.source, $0.title) < ($1.source, $1.title) }
    }

    /// Incomplete reminders plus the ones completed today, from the given lists (nil = all).
    func fetch(calendarIds: [String]?) async -> [TodoItem] {
        let all = store.calendars(for: .reminder)
        let cals = calendarIds.map { ids in all.filter { ids.contains($0.calendarIdentifier) } } ?? all
        guard !cals.isEmpty else { return [] }
        let open = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: cals)
        let doneToday = store.predicateForCompletedReminders(
            withCompletionDateStarting: Calendar.current.startOfDay(for: Date()), ending: nil, calendars: cals)
        let a = await fetch(open)
        let b = await fetch(doneToday)
        return a + b
    }

    private func fetch(_ predicate: NSPredicate) async -> [TodoItem] {
        await withCheckedContinuation { cont in
            store.fetchReminders(matching: predicate) { reminders in
                cont.resume(returning: (reminders ?? []).map(Self.item(from:)))
            }
        }
    }

    func add(_ t: TodoItem, calendarId: String) throws -> TodoItem {
        guard let cal = store.calendar(withIdentifier: calendarId) else { throw SideStatsError("Reminders list not found") }
        let r = EKReminder(eventStore: store)
        r.calendar = cal
        apply(t, to: r, isNew: true)
        try store.save(r, commit: true)
        return Self.item(from: r)
    }

    func update(_ t: TodoItem, calendarId: String?) throws -> TodoItem? {
        let r = try reminder(t.externalId)
        apply(t, to: r, isNew: false)
        if let calendarId, let cal = store.calendar(withIdentifier: calendarId), cal.allowsContentModifications {
            r.calendar = cal
        }
        try store.save(r, commit: true)
        return Self.item(from: r)
    }

    func setDone(_ externalId: String, _ done: Bool) throws {
        let r = try reminder(externalId)
        r.isCompleted = done
        try store.save(r, commit: true)
    }

    func remove(_ externalId: String) throws {
        try store.remove(try reminder(externalId), commit: true)
    }

    private func reminder(_ id: String?) throws -> EKReminder {
        guard let id, let r = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw SideStatsError("Reminder not found (it may have been deleted)")
        }
        return r
    }

    private func apply(_ t: TodoItem, to r: EKReminder, isNew: Bool) {
        r.title = t.title
        r.notes = t.notes.isEmpty ? nil : t.notes
        r.priority = Self.ekPriority(t.priority)
        if r.isCompleted != t.done { r.isCompleted = t.done }
        let old = Self.item(from: r)
        if isNew || old.due != t.due || old.allDay != t.allDay {
            r.alarms?.forEach { r.removeAlarm($0) }
            if let due = t.due {
                let comps: Set<Calendar.Component> = t.allDay ? [.year, .month, .day] : [.year, .month, .day, .hour, .minute]
                r.dueDateComponents = Calendar.current.dateComponents(comps, from: due)
                // Reminders only notifies for reminders that carry an alarm.
                if !t.allDay { r.addAlarm(EKAlarm(absoluteDate: due)) }
            } else {
                r.dueDateComponents = nil
            }
        }
    }

    // MARK: - Mapping

    nonisolated static func item(from r: EKReminder) -> TodoItem {
        var t = TodoItem(title: r.title ?? "", notes: r.notes ?? "")
        t.id = "rem-" + r.calendarItemIdentifier
        t.externalId = r.calendarItemIdentifier
        t.source = .reminders
        t.list = r.calendar?.title ?? "Reminders"
        t.listColor = r.calendar.flatMap { hex($0.cgColor) }
        if let dc = r.dueDateComponents {
            t.allDay = dc.hour == nil
            var c = dc
            if c.calendar == nil { c.calendar = Calendar.current }
            t.due = c.date.map { t.allDay ? Calendar.current.startOfDay(for: $0) : $0 }
        }
        t.done = r.isCompleted
        t.completedAt = r.completionDate
        t.createdAt = r.creationDate ?? Date()
        t.priority = todoPriority(r.priority)
        return t
    }

    /// EventKit: 0 none, 1-4 high, 5 medium, 6-9 low.
    nonisolated static func todoPriority(_ p: Int) -> Int {
        switch p {
        case 1...4: return 3
        case 5: return 2
        case 6...9: return 1
        default: return 0
        }
    }

    nonisolated static func ekPriority(_ p: Int) -> Int {
        switch p { case 3: return 1; case 2: return 5; case 1: return 9; default: return 0 }
    }

    nonisolated static func hex(_ color: CGColor?) -> String? {
        guard let color, let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let c = color.converted(to: srgb, intent: .defaultIntent, options: nil)?.components, c.count >= 3 else { return nil }
        let v = c.prefix(3).map { Int((min(1, max(0, $0)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", v[0], v[1], v[2])
    }
}
