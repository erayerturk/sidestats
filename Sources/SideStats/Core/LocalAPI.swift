import Foundation

/// Local HTTP API on 127.0.0.1 used by scripts and the MCP bridge. (Stub — implementation to be completed.)
@MainActor
final class LocalAPIServer {
    static let defaultPort: UInt16 = 48620
    static var baseURL: String { "http://127.0.0.1:\(defaultPort)" }
    init(widgets: WidgetStore, todos: TodoStore) {}
    func start() {}
}
