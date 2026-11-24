import AppKit
import SwiftUI

// MARK: - Sidebar module

/// Built-in Tasks module body (inside a collapsible ModuleCard in the sidebar).
struct TasksModuleView: View {
    @EnvironmentObject var todos: TodoStore
    @State private var draft = ""
    @FocusState private var quickAddFocused: Bool
    /// Checked rows that linger ~1 s before moving to "Completed".
    @State private var pendingDone: Set<String> = []
    @State private var editing: String?
    @State private var hovered: String?
    @State private var showCompleted = false
    @State private var expandedSections: Set<TodoDue.Bucket> = []

    private static let sectionLimit = 6

    var body: some View {
        // Re-evaluates once a minute so "overdue" / "today" stay correct; no per-row timers.
        TimelineView(.everyMinute) { ctx in
            content(now: ctx.date)
        }
    }

    @ViewBuilder private func content(now: Date) -> some View {
        let open = todos.items.filter { !$0.done }
        let grouped = Dictionary(grouping: open) { TodoDue.bucket($0, now: now) }
        let startOfDay = Calendar.current.startOfDay(for: now)
        let completed = todos.settings.showCompleted
            ? todos.items.filter { $0.done && ($0.completedAt ?? .distantPast) >= startOfDay }
                .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
            : []

        VStack(alignment: .leading, spacing: 8) {
            quickAdd
            if let err = todos.lastError {
                HStack(alignment: .top, spacing: 6) {
                    Label(err, systemImage: "exclamationmark.triangle").font(.caption2).foregroundStyle(.orange).lineLimit(3)
                    Spacer(minLength: 0)
                    Button { todos.lastError = nil } label: { Image(systemName: "xmark").font(.caption2) }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                }
            }
            if todos.settings.remindersEnabled && todos.remindersAccess != .full && todos.remindersAccess != .notDetermined {
                Label("Reminders access is off. Enable it in Settings → Modules → Tasks.", systemImage: "lock")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            if open.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal").foregroundStyle(Color.revenue)
                    Text(completed.isEmpty ? "Nothing to do. Type above to add a task." : "All done for today. Nice work.")
                }
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(.vertical, 10)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(TodoDue.Bucket.allCases, id: \.self) { b in
                        if let rows = grouped[b], !rows.isEmpty {
                            section(b, rows: sorted(rows, b), now: now)
                        }
                    }
                }
                .padding(8)
                .background(.background.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
            }

            if !completed.isEmpty { completedSection(completed, now: now) }
        }
    }

    // MARK: Quick add

    private var quickAdd: some View {
        let preview = draft.isEmpty ? nil : TodoParser.parse(draft)
        return HStack(spacing: 6) {
            Image(systemName: "plus.circle.fill").foregroundStyle(quickAddFocused ? Color.accentColor : .secondary)
            TextField("Add a task, e.g. “call bank tomorrow 10am !!”", text: $draft)
                .textFieldStyle(.plain).font(.callout)
                .focused($quickAddFocused)
                .onSubmit(submit)
                .onExitCommand { draft = ""; quickAddFocused = false }
            if let p = preview {
                if p.priority > 0 { PriorityMark(priority: p.priority) }
                if p.due != nil, let label = TodoDue.label(TodoItem(title: "", due: p.due, allDay: p.allDay)) {
                    Text(label).font(.caption2.weight(.medium)).lineLimit(1)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(.background.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(quickAddFocused ? Color.accentColor.opacity(0.5) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { focusQuickAdd() }
    }

    private func focusQuickAdd() {
        // The sidebar is a non-activating panel: make it key so the field can take keystrokes.
        if let w = NSApp.windows.first(where: { $0 is SidebarPanel }), !w.isKeyWindow { w.makeKey() }
        quickAddFocused = true
    }

    private func submit() {
        let p = TodoParser.parse(draft)
        guard !p.title.isEmpty else { return }
        withAnimation(.snappy(duration: 0.2)) {
            _ = todos.add(TodoItem(title: p.title, due: p.due, priority: p.priority, allDay: p.allDay))
        }
        draft = ""
        quickAddFocused = true
    }

    // MARK: Sections

    private func sorted(_ rows: [TodoItem], _ b: TodoDue.Bucket) -> [TodoItem] {
        rows.sorted { a, c in
            if b != .none, let da = a.due, let dc = c.due, da != dc {
                // all-day items first within a day
                return da < dc
            }
            if a.priority != c.priority { return a.priority > c.priority }
            return a.createdAt < c.createdAt
        }
    }

    private func title(_ b: TodoDue.Bucket) -> String {
        switch b {
        case .overdue: return "Overdue"
        case .today: return "Today"
        case .upcoming: return "Upcoming"
        case .none: return "No date"
        }
    }

    @ViewBuilder private func section(_ b: TodoDue.Bucket, rows: [TodoItem], now: Date) -> some View {
        let expanded = expandedSections.contains(b) || rows.count <= Self.sectionLimit + 1
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(title(b).uppercased())
                Text("\(rows.count)").foregroundStyle(.tertiary)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(b == .overdue ? Color.spend : .secondary)
            .padding(.leading, 4).padding(.bottom, 2)

            ForEach(expanded ? rows : Array(rows.prefix(Self.sectionLimit))) { t in
                row(t, now: now)
            }
            if !expanded {
                Button("Show \(rows.count - Self.sectionLimit) more") {
                    withAnimation(.snappy(duration: 0.2)) { _ = expandedSections.insert(b) }
                }
                .buttonStyle(.link).font(.caption2).padding(.leading, 28)
            }
        }
    }

    @ViewBuilder private func row(_ t: TodoItem, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            TaskRow(item: t, now: now, checked: t.done || pendingDone.contains(t.id),
                    hovered: hovered == t.id, editing: editing == t.id,
                    onToggle: { toggle(t) },
                    onTap: { withAnimation(.snappy(duration: 0.2)) { editing = editing == t.id ? nil : t.id } },
                    onDelete: { delete(t) })
                .onHover { inside in
                    if inside { hovered = t.id } else if hovered == t.id { hovered = nil }
                }
            if editing == t.id {
                TaskEditor(original: t,
                           onSave: { updated in
                               withAnimation(.snappy(duration: 0.2)) { todos.update(updated); editing = nil }
                           },
                           onCancel: { withAnimation(.snappy(duration: 0.2)) { editing = nil } },
                           onDelete: { delete(t) })
                    .padding(.leading, 26).padding(.trailing, 4).padding(.vertical, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .transition(.opacity)
    }

    private func completedSection(_ items: [TodoItem], now: Date) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { showCompleted.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(showCompleted ? 90 : 0))
                    Text("Completed today (\(items.count))")
                }
                .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).padding(.leading, 4)
            if showCompleted {
                ForEach(items) { t in row(t, now: now) }
            }
        }
    }

    // MARK: Actions

    private func toggle(_ t: TodoItem) {
        if t.done {
            withAnimation(.snappy(duration: 0.2)) { todos.setDone(t.id, false) }
            return
        }
        if pendingDone.contains(t.id) {
            withAnimation(.snappy(duration: 0.15)) { _ = pendingDone.remove(t.id) }
            return
        }
        withAnimation(.spring(duration: 0.25, bounce: 0.4)) { _ = pendingDone.insert(t.id) }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard pendingDone.contains(t.id) else { return }
            withAnimation(.snappy(duration: 0.25)) {
                todos.setDone(t.id, true)
                pendingDone.remove(t.id)
                if editing == t.id { editing = nil }
            }
        }
    }

    private func delete(_ t: TodoItem) {
        withAnimation(.snappy(duration: 0.2)) {
            if editing == t.id { editing = nil }
            todos.remove(t.id)
        }
    }
}

// MARK: - Row

private struct TaskRow: View {
    var item: TodoItem
    var now: Date
    var checked: Bool
    var hovered: Bool
    var editing: Bool
    var onToggle: () -> Void
    var onTap: () -> Void
    var onDelete: () -> Void

    var body: some View {
        let overdue = !checked && TodoDue.isOverdue(item, now: now)
        HStack(alignment: .top, spacing: 8) {
            Button(action: onToggle) {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(checked ? Color.revenue : item.priority == 3 ? Color.spend : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
                    .scaleEffect(checked ? 1.08 : 1)
            }
            .buttonStyle(.plain)
            .help(checked ? "Mark as not done" : "Complete")

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if item.priority > 0 && !checked { PriorityMark(priority: item.priority) }
                    Text(item.title.isEmpty ? "Untitled" : item.title)
                        .font(.callout).lineLimit(2)
                        .strikethrough(checked, color: .secondary)
                        .foregroundStyle(checked ? .secondary : .primary)
                }
                if showMeta {
                    HStack(spacing: 6) {
                        if item.isReminder || item.list != TodoStore.localList {
                            HStack(spacing: 3) {
                                Circle().fill(Color.named(item.listColor, default: .secondary)).frame(width: 6, height: 6)
                                Text(item.list).lineLimit(1)
                            }
                            .help(item.isReminder ? "Apple Reminders · \(item.list)" : "List: \(item.list)")
                        }
                        if !item.notes.isEmpty {
                            Image(systemName: "note.text").help(item.notes)
                        }
                    }
                    .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let due = TodoDue.label(item, now: now) {
                Text(due)
                    .font(.caption2.weight(overdue ? .semibold : .regular)).monospacedDigit().lineLimit(1)
                    .foregroundStyle(overdue ? Color.spend : .secondary)
                    .padding(.top, 2)
            }
            if hovered && !editing {
                Button(action: onDelete) {
                    Image(systemName: "trash").font(.caption)
                }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help("Delete")
                .padding(.top, 1)
            }
        }
        .padding(.vertical, 4).padding(.horizontal, 4)
        .background((hovered || editing) ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .opacity(checked && !item.done ? 0.75 : 1)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }

    private var showMeta: Bool { item.isReminder || item.list != TodoStore.localList || !item.notes.isEmpty }
}

private struct PriorityMark: View {
    var priority: Int
    var body: some View {
        Text(String(repeating: "!", count: min(3, max(1, priority))))
            .font(.caption.weight(.heavy))
            .foregroundStyle(priority >= 3 ? Color.spend : priority == 2 ? .orange : .blue)
    }
}

// MARK: - Inline editor

private struct TaskEditor: View {
    var original: TodoItem
    var onSave: (TodoItem) -> Void
    var onCancel: () -> Void
    var onDelete: () -> Void
    @State private var draft: TodoItem
    @FocusState private var titleFocused: Bool

    init(original: TodoItem, onSave: @escaping (TodoItem) -> Void, onCancel: @escaping () -> Void, onDelete: @escaping () -> Void) {
        self.original = original
        self.onSave = onSave
        self.onCancel = onCancel
        self.onDelete = onDelete
        _draft = State(initialValue: original)
    }

    private var hasDue: Binding<Bool> {
        Binding(get: { draft.due != nil },
                set: { draft.due = $0 ? (draft.due ?? defaultDue()) : nil })
    }

    private var dueDate: Binding<Date> {
        Binding(get: { draft.due ?? defaultDue() },
                set: { draft.due = draft.allDay ? Calendar.current.startOfDay(for: $0) : $0 })
    }

    private func defaultDue() -> Date {
        draft.allDay ? Calendar.current.startOfDay(for: Date())
            : Calendar.current.date(bySettingHour: 17, minute: 0, second: 0, of: Date()) ?? Date()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Title", text: $draft.title)
                .textFieldStyle(.roundedBorder).font(.callout)
                .focused($titleFocused)
                .onSubmit(save)
            TextField("Notes", text: $draft.notes, axis: .vertical)
                .textFieldStyle(.roundedBorder).font(.caption).lineLimit(1...4)

            HStack(spacing: 6) {
                Toggle("Due", isOn: hasDue).toggleStyle(.checkbox).font(.caption)
                if draft.due != nil {
                    DatePicker("", selection: dueDate,
                               displayedComponents: draft.allDay ? [.date] : [.date, .hourAndMinute])
                        .datePickerStyle(.field).labelsHidden().controlSize(.small)
                    Toggle("All day", isOn: Binding(get: { draft.allDay }, set: { on in
                        draft.allDay = on
                        if let d = draft.due {
                            draft.due = on ? Calendar.current.startOfDay(for: d)
                                : Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: d)
                        }
                    }))
                    .toggleStyle(.checkbox).font(.caption)
                }
            }
            HStack(spacing: 4) {
                quick("Today", days: 0)
                quick("Tomorrow", days: 1)
                quick("Next week", days: 7)
                if draft.due != nil {
                    Button("Clear") { draft.due = nil; draft.allDay = false }
                        .buttonStyle(.link).font(.caption2)
                }
            }

            Picker("Priority", selection: $draft.priority) {
                Text("None").tag(0)
                Text("!").tag(1)
                Text("!!").tag(2)
                Text("!!!").tag(3)
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.small)

            HStack(spacing: 8) {
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                    .buttonStyle(.borderless).foregroundStyle(Color.spend).help("Delete")
                if original.isReminder {
                    Label(original.list, systemImage: "list.bullet.circle").font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer()
                Button("Cancel", action: onCancel).controlSize(.small)
                Button("Save", action: save).controlSize(.small).keyboardShortcut(.defaultAction)
                    .disabled(draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(8)
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .onExitCommand(perform: onCancel)
        .onAppear { titleFocused = true }
    }

    private func quick(_ label: String, days: Int) -> some View {
        Button(label) {
            let cal = Calendar.current
            let day = cal.date(byAdding: .day, value: days, to: cal.startOfDay(for: Date())) ?? Date()
            if draft.allDay || draft.due == nil {
                draft.allDay = true
                draft.due = day
            } else if let d = draft.due {
                let hm = cal.dateComponents([.hour, .minute], from: d)
                draft.due = cal.date(bySettingHour: hm.hour ?? 9, minute: hm.minute ?? 0, second: 0, of: day)
            }
        }
        .buttonStyle(.bordered).controlSize(.mini).font(.caption2)
    }

    private func save() {
        guard !draft.title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if draft != original { onSave(draft) } else { onCancel() }
    }
}

// MARK: - Settings pane

/// Tasks settings pane shown in Settings → Modules.
struct TasksSettingsView: View {
    @EnvironmentObject var todos: TodoStore
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section {
                Toggle("Show Apple Reminders", isOn: $todos.settings.remindersEnabled)
                if todos.settings.remindersEnabled { remindersStatus }
            } header: {
                Text("Apple Reminders")
            } footer: {
                Text("Incomplete reminders from the selected lists appear next to your local tasks. Completing, editing and deleting sync back to Reminders.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if todos.remindersActive && !todos.reminderLists.isEmpty {
                Section("Lists to show") {
                    ForEach(todos.reminderLists) { l in
                        Toggle(isOn: Binding(get: { todos.isListSelected(l.id) },
                                             set: { todos.setList(l.id, selected: $0) })) {
                            HStack(spacing: 6) {
                                Circle().fill(Color.named(l.color, default: .secondary)).frame(width: 9, height: 9)
                                Text(l.title)
                                if !l.source.isEmpty { Text(l.source).font(.caption).foregroundStyle(.tertiary) }
                                if !l.writable { Text("read-only").font(.caption2).foregroundStyle(.tertiary) }
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }

            Section("New tasks") {
                Picker("Add new tasks to", selection: $todos.settings.defaultTarget) {
                    Text("SideStats (local)").tag(TodoStore.localTarget)
                    if todos.remindersActive {
                        ForEach(todos.targetLists) { l in Text("Reminders · \(l.title)").tag(l.id) }
                    }
                    // keep a stale selection representable
                    if todos.settings.defaultTarget != TodoStore.localTarget,
                       !todos.targetLists.contains(where: { $0.id == todos.settings.defaultTarget }) {
                        Text("Unavailable list (uses local)").tag(todos.settings.defaultTarget)
                    }
                }
                Text("Quick add understands dates like “tomorrow 10am” or “friday”, and !, !!, !!! for priority.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Display") {
                Toggle("Show “Completed today” section", isOn: $todos.settings.showCompleted)
            }

            Section {
                Toggle("Notify when local tasks are due", isOn: $todos.settings.notifications)
                if todos.settings.notifications { notificationStatus }
            } header: {
                Text("Notifications")
            } footer: {
                Text("Reminders-backed tasks are notified by the Reminders app.").font(.caption).foregroundStyle(.secondary)
            }

            Section("Local tasks") {
                LabeledContent("Stored", value: "\(todos.localCount) task\(todos.localCount == 1 ? "" : "s")")
                Button("Clear completed local tasks (\(todos.completedLocalCount))", role: .destructive) { confirmClear = true }
                    .disabled(todos.completedLocalCount == 0)
            }
        }
        .formStyle(.grouped)
        .onAppear { todos.recheckAccess() }
        .confirmationDialog("Delete \(todos.completedLocalCount) completed local tasks?", isPresented: $confirmClear) {
            Button("Delete", role: .destructive) { todos.clearCompletedLocal() }
        } message: {
            Text("Reminders are not affected.")
        }
    }

    @ViewBuilder private var remindersStatus: some View {
        switch todos.remindersAccess {
        case .full:
            Label("Access granted · \(todos.reminderLists.count) lists", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Color.revenue).font(.callout)
        case .notDetermined:
            HStack {
                Label("Waiting for permission…", systemImage: "hourglass").foregroundStyle(.secondary)
                Spacer()
                Button("Grant access") { todos.recheckAccess() }
            }
        case .unavailable:
            Label("Reminders needs the app bundle (run SideStats.app, not the bare binary).", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange).font(.callout)
        case .denied, .restricted, .writeOnly:
            VStack(alignment: .leading, spacing: 6) {
                Label(todos.remindersAccess == .writeOnly
                      ? "SideStats only has add-only access. Allow Full Access to show reminders."
                      : "SideStats is not allowed to access Reminders.",
                      systemImage: "lock.fill")
                    .foregroundStyle(.orange).font(.callout)
                HStack {
                    Button("Open Privacy Settings") {
                        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")
                    }
                    Button("Check again") { todos.recheckAccess() }
                }
            }
        }
    }

    @ViewBuilder private var notificationStatus: some View {
        switch todos.notificationStatus {
        case .authorized:
            Label("Notifications allowed", systemImage: "bell.badge").foregroundStyle(.secondary).font(.callout)
        case .denied:
            HStack {
                Label("Notifications are blocked", systemImage: "bell.slash").foregroundStyle(.orange).font(.callout)
                Spacer()
                Button("Open Settings") { open("x-apple.systempreferences:com.apple.Notifications-Settings.extension") }
            }
        case .notDetermined:
            HStack {
                Text("Permission is requested the first time a task has a due date.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Allow now") { todos.requestNotificationPermission() }
            }
        case .unknown:
            EmptyView()
        }
    }

    private func open(_ url: String) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }
}
