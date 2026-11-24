import Foundation

/// A task / reminder shown in the built-in Tasks module. (Contract — implementation to be completed.)
struct TodoItem: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var title: String
    var notes = ""
    var due: Date?
    var done = false
    var priority = 0            // 0 none, 1 low, 2 medium, 3 high
    var list = "Inbox"
    var createdAt = Date()
    var completedAt: Date?
}

@MainActor
final class TodoStore: ObservableObject {
    @Published private(set) var items: [TodoItem] = []

    @discardableResult
    func add(title: String, notes: String = "", due: Date? = nil, priority: Int = 0, list: String? = nil) -> TodoItem {
        let t = TodoItem(title: title, notes: notes, due: due, priority: priority, list: list ?? "Inbox")
        items.append(t)
        return t
    }

    func setDone(_ id: String, _ done: Bool) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].done = done
        items[i].completedAt = done ? Date() : nil
    }

    func update(_ item: TodoItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i] = item
    }

    func remove(_ id: String) { items.removeAll { $0.id == id } }
}
