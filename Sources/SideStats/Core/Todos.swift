import Foundation

/// A task shown in the built-in Tasks module: either a local task (saved in Application Support)
/// or a mirror of an incomplete Apple Reminders item (`source == .reminders`).
struct TodoItem: Codable, Identifiable, Equatable, Hashable {
    enum Source: String, Codable { case local, reminders }

    var id = UUID().uuidString
    var title: String
    var notes = ""
    var due: Date?
    var done = false
    var priority = 0            // 0 none, 1 low, 2 medium, 3 high
    var list = TodoStore.localList
    var createdAt = Date()
    var completedAt: Date?
    /// `due` is a day (stored as start of that day) without a time.
    var allDay = false
    var source: Source = .local
    /// `EKReminder.calendarItemIdentifier` for reminder-backed items.
    var externalId: String?
    /// Reminders list color (#RRGGBB) for reminder-backed items.
    var listColor: String?

    var isReminder: Bool { source == .reminders }
}

extension TodoItem {
    /// Lenient decoding: only `title` is required, so older files and API payloads still decode.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        due = try c.decodeIfPresent(Date.self, forKey: .due)
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
        priority = min(3, max(0, try c.decodeIfPresent(Int.self, forKey: .priority) ?? 0))
        list = try c.decodeIfPresent(String.self, forKey: .list) ?? TodoStore.localList
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        allDay = try c.decodeIfPresent(Bool.self, forKey: .allDay) ?? false
        source = (try? c.decodeIfPresent(Source.self, forKey: .source)) ?? .local
        externalId = try c.decodeIfPresent(String.self, forKey: .externalId)
        listColor = try c.decodeIfPresent(String.self, forKey: .listColor)
    }
}

struct TodoSettings: Codable, Equatable {
    var remindersEnabled = false
    /// Reminders calendar identifiers to show; nil = all lists.
    var reminderListIds: [String]?
    /// "local" or a Reminders calendar identifier.
    var defaultTarget = TodoStore.localTarget
    var showCompleted = true
    var notifications = true

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        remindersEnabled = try c.decodeIfPresent(Bool.self, forKey: .remindersEnabled) ?? false
        reminderListIds = try c.decodeIfPresent([String].self, forKey: .reminderListIds)
        defaultTarget = try c.decodeIfPresent(String.self, forKey: .defaultTarget) ?? TodoStore.localTarget
        showCompleted = try c.decodeIfPresent(Bool.self, forKey: .showCompleted) ?? true
        notifications = try c.decodeIfPresent(Bool.self, forKey: .notifications) ?? true
    }
}

/// A Reminders list (EKCalendar) as plain data.
struct ReminderList: Identifiable, Equatable, Hashable {
    var id: String
    var title: String
    var color: String?
    var source: String
    var writable: Bool
}

enum RemindersAccess: Equatable { case notDetermined, full, denied, restricted, writeOnly, unavailable }

@MainActor
final class TodoStore: ObservableObject {
    nonisolated static let localList = "Inbox"
    nonisolated static let localTarget = "local"

    /// Local tasks followed by reminder-backed items (everything the UI and the local API see).
    @Published private(set) var items: [TodoItem] = []
    @Published var settings: TodoSettings {
        didSet { if settings != oldValue { settingsChanged(from: oldValue) } }
    }
    @Published private(set) var remindersAccess: RemindersAccess = .notDetermined
    @Published private(set) var reminderLists: [ReminderList] = []
    @Published private(set) var notificationStatus: TodoNotifier.Status = .unknown
    @Published var lastError: String?

    private var local: [TodoItem] = []
    private var remote: [TodoItem] = []
    private let fileName: String
    private let settingsFile: String
    private var bridge: TodoReminders?
    private let notifier = TodoNotifier()
    private var refreshTask: Task<Void, Never>?

    init(fileName: String = "todos.json") {
        self.fileName = fileName
        settingsFile = fileName.replacingOccurrences(of: ".json", with: "") + "-settings.json"
        local = Storage.load([TodoItem].self, fileName) ?? []
        settings = Storage.load(TodoSettings.self, settingsFile) ?? TodoSettings()
        rebuild()
        notifier.onStatus = { [weak self] s in self?.notificationStatus = s }
        notifier.sync(local, enabled: settings.notifications, prompt: false)
        remindersAccess = TodoReminders.access
        if settings.remindersEnabled && remindersAccess == .full {
            Task { await activateReminders() }
        }
    }

    // MARK: - Contract API

    @discardableResult
    func add(title: String, notes: String = "", due: Date? = nil, priority: Int = 0, list: String? = nil) -> TodoItem {
        add(TodoItem(title: title, notes: notes, due: due, priority: priority), toList: list)
    }

    func setDone(_ id: String, _ done: Bool) {
        if let i = local.firstIndex(where: { $0.id == id }) {
            guard local[i].done != done else { return }
            local[i].done = done
            local[i].completedAt = done ? Date() : nil
            localChanged()
        } else if let i = remote.firstIndex(where: { $0.id == id }), let ext = remote[i].externalId, let bridge {
            do {
                try bridge.setDone(ext, done)
                remote[i].done = done
                remote[i].completedAt = done ? Date() : nil
                rebuild()
            } catch { fail(error) }
        }
    }

    func update(_ item: TodoItem) {
        var item = item
        item.priority = min(3, max(0, item.priority))
        item.title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let i = local.firstIndex(where: { $0.id == item.id }) {
            let old = local[i]
            item.source = .local; item.externalId = nil; item.createdAt = old.createdAt
            if item.done != old.done { item.completedAt = item.done ? (item.completedAt ?? Date()) : nil }
            if item.allDay, let d = item.due { item.due = Calendar.current.startOfDay(for: d) }
            if item.list.isEmpty { item.list = Self.localList }
            local[i] = item
            localChanged()
        } else if let i = remote.firstIndex(where: { $0.id == item.id }), let bridge {
            let old = remote[i]
            item.source = .reminders; item.externalId = old.externalId
            let calendarId = item.list == old.list ? nil : reminderList(named: item.list)?.id
            do {
                if let updated = try bridge.update(item, calendarId: calendarId) { remote[i] = updated }
                rebuild()
            } catch { fail(error) }
        }
    }

    func remove(_ id: String) {
        if local.contains(where: { $0.id == id }) {
            local.removeAll { $0.id == id }
            localChanged()
        } else if let i = remote.firstIndex(where: { $0.id == id }), let ext = remote[i].externalId, let bridge {
            do {
                try bridge.remove(ext)
                remote.remove(at: i)
                rebuild()
            } catch { fail(error) }
        }
    }

    // MARK: - Extended API

    /// Adds a fully specified task. `list` routes it: a Reminders list title (or id) adds a reminder,
    /// any other name a local task in that list; nil uses the default target from settings.
    @discardableResult
    func add(_ draft: TodoItem, toList list: String? = nil) -> TodoItem {
        var t = draft
        t.title = t.title.trimmingCharacters(in: .whitespacesAndNewlines)
        t.priority = min(3, max(0, t.priority))
        if t.allDay, let d = t.due { t.due = Calendar.current.startOfDay(for: d) }
        if let calendarId = target(for: list), let bridge {
            do {
                let r = try bridge.add(t, calendarId: calendarId)
                remote.append(r)
                rebuild()
                return r
            } catch { fail(error) }
        }
        t.id = UUID().uuidString
        t.source = .local; t.externalId = nil; t.listColor = nil
        t.list = list.flatMap { $0.isEmpty ? nil : $0 } ?? (t.list.isEmpty ? Self.localList : t.list)
        t.createdAt = Date()
        if t.done { t.completedAt = t.completedAt ?? Date() }
        local.append(t)
        localChanged(prompt: t.due != nil)
        return t
    }

    func clearCompletedLocal() {
        local.removeAll(where: \.done)
        localChanged()
    }

    var completedLocalCount: Int { local.filter(\.done).count }
    var openCount: Int { items.filter { !$0.done }.count }
    var overdueCount: Int { items.filter { TodoDue.isOverdue($0) }.count }
    var localCount: Int { local.count }
    var remindersActive: Bool { settings.remindersEnabled && remindersAccess == .full && bridge != nil }

    /// Lists offered as targets for new tasks (selected, writable Reminders lists).
    var targetLists: [ReminderList] {
        reminderLists.filter { $0.writable && isListSelected($0.id) }
    }

    func isListSelected(_ id: String) -> Bool { settings.reminderListIds?.contains(id) ?? true }

    func setList(_ id: String, selected: Bool) {
        var ids = Set(settings.reminderListIds ?? reminderLists.map(\.id))
        if selected { ids.insert(id) } else { ids.remove(id) }
        settings.reminderListIds = reminderLists.map(\.id).filter(ids.contains)
    }

    /// Re-reads authorization (e.g. after the user changed it in System Settings) and reloads.
    func recheckAccess() {
        remindersAccess = TodoReminders.access
        notifier.refreshStatus()
        if settings.remindersEnabled { Task { await activateReminders() } }
    }

    func requestNotificationPermission() { notifier.sync(local, enabled: settings.notifications, prompt: true, force: true) }

    func refreshReminders() async {
        guard remindersActive, let bridge else { return }
        reminderLists = bridge.lists()
        let ids = settings.reminderListIds
        let fetched = await bridge.fetch(calendarIds: ids)
        guard remindersActive, ids == settings.reminderListIds else { return }
        remote = fetched
        rebuild()
    }

    // MARK: - Internals

    private func target(for list: String?) -> String? {
        guard remindersActive else { return nil }
        if let list, !list.isEmpty {
            return reminderList(named: list).flatMap { $0.writable ? $0.id : nil }
        }
        let d = settings.defaultTarget
        guard d != Self.localTarget, reminderLists.contains(where: { $0.id == d && $0.writable }) else { return nil }
        return d
    }

    private func reminderList(named name: String) -> ReminderList? {
        reminderLists.first { $0.id == name }
            ?? reminderLists.first { $0.title.caseInsensitiveCompare(name) == .orderedSame }
    }

    private func rebuild() { items = local + remote }

    private func localChanged(prompt: Bool = false) {
        rebuild()
        Storage.save(local, fileName)
        notifier.sync(local, enabled: settings.notifications, prompt: prompt)
    }

    private func fail(_ error: Error) {
        lastError = error.localizedDescription
    }

    private func settingsChanged(from old: TodoSettings) {
        Storage.save(settings, settingsFile)
        if settings.remindersEnabled != old.remindersEnabled {
            Task { await activateReminders() }
        } else if settings.reminderListIds != old.reminderListIds {
            Task { await refreshReminders() }
        }
        if settings.notifications != old.notifications {
            notifier.sync(local, enabled: settings.notifications, prompt: settings.notifications)
        }
    }

    private func activateReminders() async {
        guard settings.remindersEnabled else {
            bridge?.stop(); bridge = nil
            remote = []; reminderLists = []
            rebuild()
            return
        }
        guard TodoReminders.canRequest else {
            remindersAccess = .unavailable
            return
        }
        let b = bridge ?? TodoReminders()
        bridge = b
        var access = TodoReminders.access
        if access == .notDetermined {
            _ = await b.requestAccess()
            access = TodoReminders.access
        }
        remindersAccess = access
        guard access == .full, settings.remindersEnabled else {
            remote = []; reminderLists = []
            rebuild()
            return
        }
        b.start { [weak self] in self?.scheduleRefresh() }
        await refreshReminders()
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.refreshReminders()
        }
    }
}
