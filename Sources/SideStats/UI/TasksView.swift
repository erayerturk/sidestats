import SwiftUI

/// Built-in Tasks module body. (Placeholder — implementation to be completed.)
struct TasksModuleView: View {
    @EnvironmentObject var todos: TodoStore
    var body: some View {
        Text("\(todos.items.count) tasks").font(.caption).foregroundStyle(.secondary)
    }
}

/// Tasks settings pane shown in Settings → Modules. (Placeholder.)
struct TasksSettingsView: View {
    var body: some View { Form { Text("Tasks") }.formStyle(.grouped) }
}
