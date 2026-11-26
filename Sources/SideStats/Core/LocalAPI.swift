import AppKit
import Foundation
import Network
import UserNotifications

/// Connection details the MCP bridge (`SideStats --mcp`) reads to reach the running app.
/// Written to `Storage.dir/api.json` with 0600 permissions.
struct LocalAPIInfo: Codable {
    var port: Int
    var token: String
    var pid: Int32
    var version: String
    var baseURL: String
    var executable: String

    static var fileURL: URL { Storage.dir.appendingPathComponent("api.json") }

    static func read() -> LocalAPIInfo? {
        guard let d = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(LocalAPIInfo.self, from: d)
    }
}

enum AppVersion {
    static var string: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }
    /// Path of the running executable (symlinks resolved).
    static var executablePath: String {
        (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .resolvingSymlinksInPath().path
    }
}

/// Local HTTP API on 127.0.0.1 used by scripts and the MCP bridge.
///
/// Security model: binds to the loopback interface only, every request needs the bearer token
/// (random, stored in a 0600 file readable only by this user), requests with
/// an `Origin` header (browsers) or a foreign `Host` (DNS rebinding) are refused, and there is no CORS.
@MainActor
final class LocalAPIServer: ObservableObject {
    static let defaultPort: UInt16 = 48620
    private static let maxPortAttempts: UInt16 = 20
    static private(set) var currentPort: UInt16 = defaultPort
    static var baseURL: String { "http://127.0.0.1:\(currentPort)" }
    static weak var shared: LocalAPIServer?

    @Published private(set) var port: UInt16?
    @Published private(set) var lastError: String?
    @Published private(set) var token = ""
    @Published private(set) var requestCount = 0
    var isRunning: Bool { port != nil }

    let widgets: WidgetStore
    let todos: TodoStore
    let store: MetricsStore
    /// Set by the app delegate: performs show|hide|toggle|pin|unpin and returns the panel state.
    var panelControl: ((String) -> [String: Any])?

    private var listener: NWListener?

    init(widgets: WidgetStore, todos: TodoStore, store: MetricsStore) {
        self.widgets = widgets
        self.todos = todos
        self.store = store
        Self.shared = self
    }

    // MARK: lifecycle

    func start() {
        // The token lives only in the 0600 api.json (readable by this user only, which is also how the
        // MCP bridge finds it). It is not kept in the Keychain: ad-hoc signed builds change their code
        // signature on every update, which would make every launch block on a Keychain prompt.
        if let t = LocalAPIInfo.read()?.token, t.hasPrefix("sst_") { token = t } else { token = Self.newToken() }
        listen(on: Self.defaultPort, attempt: 0)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = nil
        // api.json is kept so the token survives restarts; the MCP bridge checks the pid for liveness.
    }

    func regenerateToken() {
        token = Self.newToken()
        writeInfo()
    }


    private static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        }
        return "sst_" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func listen(on p: UInt16, attempt: UInt16) {
        let params = NWParameters.tcp
        params.acceptLocalOnly = true
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: p)!)
        let l: NWListener
        do { l = try NWListener(using: params) } catch {
            lastError = "Could not start the local API: \(error.localizedDescription)"
            return
        }
        listener = l
        l.newConnectionHandler = { [weak self] conn in
            MainActor.assumeIsolated {
                guard let self else { conn.cancel(); return }
                HTTPConnection(conn, server: self).start()
            }
        }
        l.stateUpdateHandler = { [weak self, weak l] state in
            MainActor.assumeIsolated {
                guard let self, let l, self.listener === l else { return }
                switch state {
                case .ready:
                    self.port = p
                    self.lastError = nil
                    Self.currentPort = p
                    self.writeInfo()
                case .failed(let e), .waiting(let e):
                    l.cancel()
                    self.listener = nil
                    self.port = nil
                    if attempt + 1 < Self.maxPortAttempts {
                        self.listen(on: p + 1, attempt: attempt + 1)
                    } else {
                        self.lastError = "No free port in \(Self.defaultPort)–\(Self.defaultPort + Self.maxPortAttempts - 1): \(e.localizedDescription)"
                    }
                default: break
                }
            }
        }
        l.start(queue: .main)
    }

    private func writeInfo() {
        guard let port else { return }
        let info = LocalAPIInfo(port: Int(port), token: token, pid: ProcessInfo.processInfo.processIdentifier,
                                version: AppVersion.string, baseURL: Self.baseURL, executable: AppVersion.executablePath)
        guard let data = try? JSONEncoder().encode(info) else { return }
        let final = LocalAPIInfo.fileURL.path
        let tmp = final + ".tmp"
        unlink(tmp)
        guard FileManager.default.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: 0o600]) else {
            lastError = "Could not write \(final)"
            return
        }
        chmod(tmp, 0o600)
        if rename(tmp, final) != 0 { lastError = "Could not write \(final)" }
    }

    // MARK: request handling

    fileprivate func handle(_ req: HTTPRequest) async -> HTTPResponse {
        requestCount += 1
        if let origin = req.headers["origin"] {
            return .error(403, "Requests from browsers are not allowed (Origin: \(origin)).")
        }
        if let host = req.headers["host"], !Self.allowedHost(host) {
            return .error(403, "Invalid Host header \(host). Use http://127.0.0.1:\(port ?? Self.defaultPort).")
        }
        guard let auth = req.headers["authorization"], auth.lowercased().hasPrefix("bearer "),
              Self.constantTimeEqual(String(auth.dropFirst(7)).trimmingCharacters(in: .whitespaces), token) else {
            return .error(401, "Missing or invalid token.",
                          hint: "Send 'Authorization: Bearer <token>'. The token is in \(LocalAPIInfo.fileURL.path) and in Settings → API & MCP.")
        }
        do {
            return try await route(req)
        } catch let e as APIError {
            return .error(e.status, e.message, hint: e.hint)
        } catch {
            return .error(400, error.localizedDescription)
        }
    }

    nonisolated static func allowedHost(_ host: String) -> Bool {
        var h = host.lowercased()
        if h.hasPrefix("[") { h = String(h.prefix { $0 != "]" }.dropFirst()) }
        else if let i = h.lastIndex(of: ":") { h = String(h[..<i]) }
        return h == "127.0.0.1" || h == "localhost" || h == "::1"
    }

    nonisolated static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count, !y.isEmpty else { return false }
        var diff: UInt8 = 0
        for i in x.indices { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    private func route(_ req: HTTPRequest) async throws -> HTTPResponse {
        let p = req.path.split(separator: "/").map(String.init)
        guard p.first == "v1" else {
            if p.isEmpty { return .json(endpointList()) }
            throw APIError(404, "Unknown path \(req.path). All endpoints start with /v1.", hint: "GET /v1/status")
        }
        let rest = Array(p.dropFirst())
        switch (req.method, rest.count, rest.first ?? "") {
        case ("GET", 0, _): return .json(endpointList())
        case ("GET", 1, "status"): return .json(status())
        case ("GET", 1, "format"): return .json(["format": MCPDocs.widgetFormat])
        case ("GET", 1, "modules"): return .json(["modules": modules()])
        case ("POST", 1, "layout"): return .json(try layout(req.object()))

        case ("GET", 1, "widgets"): return .json(["widgets": widgets.widgets.map { widgetJSON($0, includeHeaders: false) }])
        case ("POST", 1, "widgets"): return try createWidgets(req)
        case (_, 2, "widgets"), (_, 3, "widgets"):
            let id = rest[1]
            guard widgets.widget(id) != nil else {
                throw APIError(404, "No widget with id \(id).", hint: "GET /v1/modules lists widget ids.")
            }
            switch (req.method, rest.count == 3 ? rest[2] : "") {
            case ("GET", ""): return .json(widgetJSON(widgets.widget(id)!, includeHeaders: true))
            case ("PATCH", ""), ("PUT", ""): return .json(try updateWidget(id, req.object()))
            case ("DELETE", ""):
                widgets.remove(id)
                return .json(["ok": true, "deleted": id])
            case ("POST", "data"), ("PUT", "data"): return .json(try pushData(id, req.anyBody()))
            case ("POST", "refresh"): return .json(try await refreshWidget(id))
            case ("GET", "export"): return .json(["json": widgets.export(id) ?? ""])
            default: throw methodNotAllowed(req)
            }

        case ("GET", 1, "presets"): return .json(["presets": WidgetPresets.all.map(presetJSON)])
        case ("POST", 2, "presets"): return try createFromPreset(rest[1], req.object(allowEmpty: true))

        case ("GET", 1, "todos"): return .json(listTodos(req.query))
        case ("POST", 1, "todos"): return .json(try addTodo(req.object()), status: 201)
        case (_, 2, "todos"):
            let id = rest[1]
            guard todos.items.contains(where: { $0.id == id }) else {
                throw APIError(404, "No task with id \(id).", hint: "GET /v1/todos lists task ids.")
            }
            switch req.method {
            case "GET": return .json(todoJSON(todos.items.first { $0.id == id }!))
            case "PATCH", "PUT": return .json(try updateTodo(id, req.object()))
            case "DELETE":
                todos.remove(id)
                return .json(["ok": true, "deleted": id])
            default: throw methodNotAllowed(req)
            }

        case ("GET", 1, "revenue"): return .json(try revenue(req.query))
        case (_, 2, "revenue"), (_, 3, "revenue"):
            switch (req.method, rest[1], rest.count == 3 ? rest[2] : nil) {
            case ("GET", "format", nil):
                return .json(["format": RevenueFormat.example, "fields": RevenueFormat.fieldHelp])
            case ("GET", "sources", nil):
                return .json(["sources": store.config.revenueSources.map(revenueSourceJSON)])
            case ("POST", "sources", nil):
                return .json(try createRevenueSource(req.object()), status: 201)
            case ("DELETE", "sources", let rawId?):
                let id = rawId.removingPercentEncoding ?? rawId
                guard let s = store.config.revenueSources.first(where: { $0.id == id || $0.name == id }) else {
                    throw APIError(404, "No revenue source \(id).", hint: "GET /v1/revenue/sources")
                }
                store.config.revenueSources.removeAll { $0.id == s.id }
                s.headers = ""
                try? FileManager.default.removeItem(at: CustomRevenue.pushPath(s.id))
                await store.refresh(only: [.custom])
                return .json(["ok": true, "deleted": s.id])
            case ("POST", "data", nil), ("PUT", "data", nil):
                return .json(try await pushRevenue(req.object()))
            default: throw methodNotAllowed(req)
            }
        case ("POST", 1, "notify"): return .json(try await notify(req.object()))
        case ("POST", 1, "panel"): return .json(try panel(req.object()))
        default:
            throw APIError(404, "Unknown endpoint \(req.method) \(req.path).", hint: "GET /v1 lists all endpoints.")
        }
    }

    private func methodNotAllowed(_ req: HTTPRequest) -> APIError {
        APIError(405, "\(req.method) is not supported on \(req.path).", hint: "GET /v1 lists all endpoints.")
    }

    private func endpointList() -> [String: Any] {
        ["app": "SideStats", "version": AppVersion.string, "endpoints": [
            "GET /v1/status", "GET /v1/format", "GET /v1/modules", "POST /v1/layout",
            "GET /v1/widgets", "POST /v1/widgets", "GET|PATCH|DELETE /v1/widgets/{id}",
            "POST /v1/widgets/{id}/data", "POST /v1/widgets/{id}/refresh", "GET /v1/widgets/{id}/export",
            "GET /v1/presets", "POST /v1/presets/{id}",
            "GET|POST /v1/todos", "GET|PATCH|DELETE /v1/todos/{id}",
            "GET /v1/revenue?range=7D|30D|MTD|90D", "POST /v1/notify", "POST /v1/panel",
        ]]
    }

    // MARK: status & modules

    private func status() -> [String: Any] {
        [
            "app": "SideStats", "version": AppVersion.string, "port": Int(port ?? 0),
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "counts": [
                "modules": widgets.layout.count, "visibleModules": widgets.visibleModules.count,
                "widgets": widgets.widgets.count, "tasks": todos.items.count,
                "openTasks": todos.items.filter { !$0.done }.count, "revenueApps": store.groups.count,
            ],
            "revenueSources": store.configuredSources.map(\.rawValue),
            "baseCurrency": store.config.baseCurrency,
        ]
    }

    private func modules() -> [[String: Any]] {
        widgets.layout.enumerated().map { i, id in
            if let title = WidgetStore.builtinTitle(id) {
                var m: [String: Any] = ["id": id, "title": title, "position": i,
                                        "kind": id == WidgetStore.tasksModule ? "tasks" : id == WidgetStore.campaignsModule ? "campaigns" : "revenue",
                                        "icon": WidgetStore.builtinIcon(id), "enabled": true,
                                        "hidden": widgets.hidden.contains(id), "collapsed": widgets.collapsed.contains(id)]
                if id == WidgetStore.tasksModule { m["openTasks"] = todos.items.filter { !$0.done }.count }
                else if id == WidgetStore.campaignsModule { m["campaigns"] = store.campaigns.count }
                else { m["apps"] = store.groups.count; m["sources"] = store.configuredSources.map(\.rawValue) }
                return m
            }
            guard let w = widgets.widget(id) else { return ["id": id, "kind": "unknown", "position": i] }
            let s = widgets.states[id]
            return [
                "id": id, "title": w.name, "kind": "widget", "position": i, "icon": w.icon,
                "hidden": widgets.hidden.contains(id), "collapsed": widgets.collapsed.contains(id),
                "enabled": w.enabled, "source": w.source.rawValue, "refreshSeconds": w.refreshSeconds,
                "updated": iso(s?.updated), "error": s?.error ?? NSNull(), "itemCount": s?.items.count ?? 0,
                "preset": w.preset,
            ]
        }
    }

    private func layout(_ body: [String: Any]) throws -> [String: Any] {
        let known = Set(widgets.layout)
        func ids(_ key: String) throws -> [String] {
            guard let v = body[key] else { return [] }
            let list: [String]
            if let s = v as? String { list = [s] }
            else if let a = v as? [String] { list = a }
            else { throw APIError(400, "'\(key)' must be an array of module ids.") }
            let unknown = list.filter { !known.contains($0) }
            if !unknown.isEmpty {
                throw APIError(404, "Unknown module ids in '\(key)': \(unknown.joined(separator: ", ")).",
                               hint: "Known ids: \(widgets.layout.joined(separator: ", "))")
            }
            return list
        }
        let allowed: Set = ["order", "hide", "show", "collapse", "expand", "move"]
        let extra = Set(body.keys).subtracting(allowed)
        if !extra.isEmpty || body.isEmpty {
            throw APIError(400, extra.isEmpty ? "Empty layout request." : "Unknown keys: \(extra.sorted().joined(separator: ", ")).",
                           hint: "Use any of: order [ids], hide [ids], show [ids], collapse [ids], expand [ids], move {id, to}.")
        }
        let order = try ids("order"), hide = try ids("hide"), show = try ids("show")
        let collapse = try ids("collapse"), expand = try ids("expand")
        var move: (String, Int)?
        if let m = body["move"] {
            guard let d = m as? [String: Any], let id = d["id"] as? String, let to = (d["to"] as? NSNumber)?.intValue else {
                throw APIError(400, "'move' must be {\"id\": \"…\", \"to\": index}.")
            }
            guard known.contains(id) else { throw APIError(404, "Unknown module id \(id).") }
            move = (id, to)
        }
        if !order.isEmpty {
            var seen = Set<String>()
            let first = order.filter { seen.insert($0).inserted }
            widgets.layout = first + widgets.layout.filter { !seen.contains($0) }
        }
        if let (id, to) = move, let i = widgets.layout.firstIndex(of: id) {
            var l = widgets.layout
            l.remove(at: i)
            l.insert(id, at: min(max(to, 0), l.count))
            widgets.layout = l
        }
        if !hide.isEmpty { widgets.hidden.formUnion(hide) }
        if !show.isEmpty { widgets.hidden.subtract(show) }
        if !collapse.isEmpty { widgets.collapsed.formUnion(collapse) }
        if !expand.isEmpty { widgets.collapsed.subtract(expand) }
        return ["ok": true, "modules": modules()]
    }

    // MARK: widgets

    private static let configKeys: Set<String> = {
        guard let d = try? JSONEncoder().encode(WidgetConfig()),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [] }
        return Set(o.keys)
    }()

    /// Builds a WidgetConfig from client JSON with readable validation errors.
    private func decodeConfig(_ d: [String: Any], base: WidgetConfig?) throws -> (WidgetConfig, [String]) {
        var warnings: [String] = []
        var input = d
        for k in ["data", "headers", "sidestats"] { input[k] = nil }
        let unknown = Set(input.keys).subtracting(Self.configKeys)
        if !unknown.isEmpty {
            warnings.append("Ignored unknown fields: \(unknown.sorted().joined(separator: ", ")). Valid: \(Self.configKeys.sorted().joined(separator: ", ")).")
            for k in unknown { input[k] = nil }
        }
        if let s = input["source"] {
            guard let s = s as? String, WidgetSourceType(rawValue: s) != nil else {
                throw APIError(400, "'source' must be one of: http, command, push.")
            }
        }
        if let s = input["display"] {
            guard let s = s as? String, WidgetDisplay(rawValue: s) != nil else {
                throw APIError(400, "'display' must be one of: auto, stat, chart, list, text.")
            }
        }
        var merged: [String: Any] = [:]
        if let base, let bd = try? JSONEncoder().encode(base),
           let bo = try? JSONSerialization.jsonObject(with: bd) as? [String: Any] { merged = bo }
        merged.merge(input) { _, new in new }
        if base == nil && input["source"] == nil {
            let url = (input["url"] as? String) ?? "", cmd = (input["command"] as? String) ?? ""
            merged["source"] = !url.isEmpty ? "http" : !cmd.isEmpty ? "command" : "push"
        }
        if let base { merged["id"] = base.id }
        let data = try JSONSerialization.data(withJSONObject: merged)
        let config: WidgetConfig
        do { config = try JSONDecoder().decode(WidgetConfig.self, from: data) } catch let e as DecodingError {
            throw APIError(400, "Invalid widget: \(Self.describe(e))")
        }
        switch config.source {
        case .http where config.url.trimmingCharacters(in: .whitespaces).isEmpty:
            throw APIError(400, "An http widget needs a 'url'.", hint: "Or use source \"push\" and send data to /v1/widgets/{id}/data.")
        case .command where config.command.trimmingCharacters(in: .whitespaces).isEmpty:
            throw APIError(400, "A command widget needs a 'command'.")
        default: break
        }
        return (config, warnings)
    }

    private static func describe(_ e: DecodingError) -> String {
        func path(_ c: DecodingError.Context) -> String {
            c.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
        }
        switch e {
        case .typeMismatch(let t, let c): return "field '\(path(c))' should be \(t)."
        case .valueNotFound(let t, let c): return "field '\(path(c))' is missing a \(t) value."
        case .keyNotFound(let k, _): return "missing field '\(k.stringValue)'."
        case .dataCorrupted(let c): return "\(path(c)): \(c.debugDescription)"
        @unknown default: return e.localizedDescription
        }
    }

    private static func headerLines(_ v: Any) throws -> String {
        if let s = v as? String { return s }
        if let d = v as? [String: Any] {
            return d.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        }
        throw APIError(400, "'headers' must be a string (\"Name: value\" per line) or an object {\"Name\": \"value\"}.")
    }

    private func createWidgets(_ req: HTTPRequest) throws -> HTTPResponse {
        let body = try req.anyBody()
        if let list = body as? [[String: Any]] {
            return .json(["widgets": try list.map { try createWidget($0) }], status: 201)
        }
        guard let d = body as? [String: Any] else { throw APIError(400, "Body must be a widget JSON object (or an array of them).") }
        return .json(try createWidget(d), status: 201)
    }

    private func createWidget(_ d: [String: Any]) throws -> [String: Any] {
        var (config, warnings) = try decodeConfig(d, base: nil)
        let headers = try d["headers"].map(Self.headerLines)
        if config.id.isEmpty || widgets.widget(config.id) != nil { config.id = UUID().uuidString }
        if let headers { config.headers = headers }   // before add, so the first fetch uses them
        let created = widgets.add(config)
        if created.id != config.id, let headers { created.headers = headers; config.headers = "" }
        if let data = d["data"] {
            do { try widgets.push(created.id, payload: data) } catch {
                warnings.append("Widget created, but the initial data was rejected: \(error.localizedDescription)")
            }
        }
        var out = widgetJSON(widgets.widget(created.id) ?? created, includeHeaders: true)
        if !warnings.isEmpty { out["warnings"] = warnings }
        if created.source == .push && d["data"] == nil {
            out["next"] = "POST /v1/widgets/\(created.id)/data with the payload to render."
        }
        return out
    }

    private func updateWidget(_ id: String, _ d: [String: Any]) throws -> [String: Any] {
        guard let old = widgets.widget(id), let i = widgets.widgets.firstIndex(where: { $0.id == id }) else {
            throw APIError(404, "No widget with id \(id).")
        }
        var (config, warnings) = try decodeConfig(d, base: old)
        config.id = id
        var refetch = false
        if let h = d["headers"] {
            let lines = try Self.headerLines(h)
            if lines != old.headers { config.headers = lines; refetch = true }
        }
        if config.method != old.method { refetch = true }
        widgets.widgets[i] = config
        if config.source != .push && config.enabled
            && (refetch || (widgets.states[id]?.items.isEmpty ?? true) && config != old) {
            widgets.refresh(id)
        }
        if let data = d["data"] {
            do { try widgets.push(id, payload: data) } catch {
                warnings.append("Data rejected: \(error.localizedDescription)")
            }
        }
        var out = widgetJSON(widgets.widget(id) ?? config, includeHeaders: true)
        if !warnings.isEmpty { out["warnings"] = warnings }
        return out
    }

    private func pushData(_ id: String, _ payload: Any) throws -> [String: Any] {
        do { try widgets.push(id, payload: payload) } catch {
            throw APIError(422, "Could not render the payload: \(error.localizedDescription)")
        }
        let s = widgets.states[id]
        var out: [String: Any] = ["ok": true, "id": id, "itemCount": s?.items.count ?? 0,
                                  "itemTypes": (s?.items ?? []).map(Self.itemType), "updated": iso(s?.updated)]
        if (s?.items.isEmpty ?? true) { out["warning"] = "The payload rendered no items. See GET /v1/format." }
        return out
    }

    private func refreshWidget(_ id: String) async throws -> [String: Any] {
        guard let w = widgets.widget(id) else { throw APIError(404, "No widget with id \(id).") }
        if w.source == .push {
            throw APIError(400, "'\(w.name)' is a push widget; it has nothing to fetch.",
                           hint: "Send new data with POST /v1/widgets/\(id)/data.")
        }
        widgets.refresh(id)
        let deadline = Date().addingTimeInterval(35)
        try? await Task.sleep(nanoseconds: 50_000_000)
        while widgets.states[id]?.loading == true && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return widgetJSON(widgets.widget(id) ?? w, includeHeaders: true)
    }

    private static func itemType(_ item: WidgetItem) -> String {
        switch item.kind {
        case .stat: return "stat"
        case .chart: return "chart"
        case .list: return "list"
        case .text: return "text"
        case .progress: return "progress"
        case .status: return "status"
        }
    }

    /// `headers` reads the Keychain (may prompt), so the list endpoint skips it.
    private func widgetJSON(_ w: WidgetConfig, includeHeaders: Bool) -> [String: Any] {
        var d = Self.encodeObject(w)
        let s = widgets.states[w.id]
        if includeHeaders { d["headersSet"] = !w.headers.isEmpty }
        d["hidden"] = widgets.hidden.contains(w.id)
        d["collapsed"] = widgets.collapsed.contains(w.id)
        d["position"] = widgets.layout.firstIndex(of: w.id) ?? -1
        d["state"] = [
            "updated": iso(s?.updated), "error": s?.error ?? NSNull(), "loading": s?.loading ?? false,
            "itemCount": s?.items.count ?? 0, "itemTypes": (s?.items ?? []).map(Self.itemType),
        ] as [String: Any]
        return d
    }

    // MARK: presets

    private func presetJSON(_ p: WidgetPreset) -> [String: Any] {
        [
            "id": p.id, "name": p.name, "category": p.category, "icon": p.icon, "summary": p.summary,
            "source": p.template.source.rawValue, "docs": p.docs,
            "params": p.params.map { Self.encodeObject($0) },
        ]
    }

    private func createFromPreset(_ id: String, _ body: [String: Any]) throws -> HTTPResponse {
        guard let preset = WidgetPresets.preset(id) else {
            throw APIError(404, "Unknown integration \(id).",
                           hint: "Available: \(WidgetPresets.all.map(\.id).joined(separator: ", ")). GET /v1/presets for details.")
        }
        let raw = (body["params"] as? [String: Any]) ?? body.filter { k, _ in preset.params.contains { $0.id == k } }
        let params = raw.mapValues { v -> String in (v as? String) ?? ((v as? NSNumber)?.stringValue ?? "\(v)") }
        let (config, headers): (WidgetConfig, String)
        do { (config, headers) = try WidgetPresets.make(id, params: params) } catch {
            throw APIError(400, error.localizedDescription,
                           hint: "Parameters: " + preset.params.map { "\($0.id)\($0.optional ? " (optional)" : "") — \($0.label)" }.joined(separator: "; "))
        }
        var c = config
        if let n = body["name"] as? String, !n.isEmpty { c.name = n }
        if let r = (body["refreshSeconds"] as? NSNumber)?.intValue { c.refreshSeconds = max(5, r) }
        if !headers.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { c.headers = headers }
        let created = widgets.add(c)
        if created.id != c.id, !headers.isEmpty { created.headers = headers }
        return .json(widgetJSON(widgets.widget(created.id) ?? created, includeHeaders: true), status: 201)
    }

    // MARK: todos

    private func todoJSON(_ t: TodoItem) -> [String: Any] {
        var d: [String: Any] = ["id": t.id, "title": t.title, "notes": t.notes, "done": t.done,
                                "priority": t.priority, "list": t.list, "allDay": t.allDay,
                                "createdAt": iso(t.createdAt), "due": iso(t.due), "completedAt": iso(t.completedAt)]
        if let due = t.due, !t.done { d["overdue"] = due < Date() }
        return d
    }

    private func listTodos(_ q: [String: String]) -> [String: Any] {
        var items = todos.items
        if let done = q["done"].flatMap(Self.bool) { items = items.filter { $0.done == done } }
        if let list = q["list"], !list.isEmpty { items = items.filter { $0.list.caseInsensitiveCompare(list) == .orderedSame } }
        return ["tasks": items.map(todoJSON), "count": items.count,
                "lists": Array(Set(todos.items.map(\.list))).sorted()]
    }

    private static func bool(_ s: String) -> Bool? {
        switch s.lowercased() { case "1", "true", "yes": return true; case "0", "false", "no": return false; default: return nil }
    }

    static func parsePriority(_ v: Any?) throws -> Int? {
        guard let v, !(v is NSNull) else { return nil }
        if let n = v as? NSNumber, (0...3).contains(n.intValue) { return n.intValue }
        if let s = v as? String {
            switch s.lowercased() {
            case "none", "0", "": return 0
            case "low", "1": return 1
            case "medium", "med", "2": return 2
            case "high", "3": return 3
            default: break
            }
        }
        throw APIError(400, "'priority' must be 0–3 or none|low|medium|high.")
    }

    /// ISO-8601 (with or without time / fractional seconds) or yyyy-MM-dd (local midnight).
    static func parseDue(_ v: Any?) throws -> Date?? {
        guard let v else { return .none }                 // not provided
        if v is NSNull { return .some(nil) }              // clear
        guard let s = (v as? String)?.trimmingCharacters(in: .whitespaces) else {
            throw APIError(400, "'due' must be an ISO-8601 string or yyyy-MM-dd.")
        }
        if s.isEmpty { return .some(nil) }
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        for fmt in ["yyyy-MM-dd", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm"] {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return d }
        }
        throw APIError(400, "Could not read due date '\(s)'. Use ISO-8601 (2026-11-26T15:00:00+01:00) or yyyy-MM-dd.")
    }

    /// A bare yyyy-MM-dd due date means "that day", not midnight.
    static func isDateOnly(_ v: Any?) -> Bool {
        guard let s = (v as? String)?.trimmingCharacters(in: .whitespaces) else { return false }
        return s.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }

    private func addTodo(_ d: [String: Any]) throws -> [String: Any] {
        guard let title = (d["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            throw APIError(400, "'title' is required.")
        }
        let due = try Self.parseDue(d["due"]) ?? nil
        let t = todos.add(title: title, notes: (d["notes"] as? String) ?? "", due: due,
                          priority: try Self.parsePriority(d["priority"]) ?? 0,
                          list: (d["list"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        if Self.isDateOnly(d["due"]) || (d["allDay"] as? Bool) == true, var full = todos.items.first(where: { $0.id == t.id }) {
            full.allDay = true
            todos.update(full)
        }
        if (d["done"] as? Bool) == true { todos.setDone(t.id, true) }
        return todoJSON(todos.items.first { $0.id == t.id } ?? t)
    }

    private func updateTodo(_ id: String, _ d: [String: Any]) throws -> [String: Any] {
        guard var t = todos.items.first(where: { $0.id == id }) else { throw APIError(404, "No task with id \(id).") }
        if let title = d["title"] {
            guard let s = (title as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
                throw APIError(400, "'title' must be a non-empty string.")
            }
            t.title = s
        }
        if let n = d["notes"] as? String { t.notes = n }
        if let l = d["list"] as? String, !l.isEmpty { t.list = l }
        if let p = try Self.parsePriority(d["priority"]) { t.priority = p }
        if let due = try Self.parseDue(d["due"]) { t.due = due; t.allDay = Self.isDateOnly(d["due"]) }
        if let allDay = d["allDay"] as? Bool { t.allDay = allDay }
        todos.update(t)
        if let done = d["done"] as? Bool, done != t.done { todos.setDone(id, done) }
        return todoJSON(todos.items.first { $0.id == id } ?? t)
    }

    // MARK: revenue

    private func revenueSourceJSON(_ s: WidgetConfig) -> [String: Any] {
        var d: [String: Any] = ["id": s.id, "name": s.name, "source": s.source.rawValue, "enabled": s.enabled,
                                "preset": s.preset, "transform": s.transform, "jsonPath": s.jsonPath]
        if s.source == .http { d["url"] = s.url; d["method"] = s.method }
        if s.source == .command { d["command"] = s.command }
        return d
    }

    private func createRevenueSource(_ o: [String: Any]) throws -> [String: Any] {
        var s: WidgetConfig
        var headers = ""
        if let pid = o["preset"] as? String, !pid.isEmpty {
            guard let p = RevenuePreset.preset(pid) else {
                throw APIError(400, "Unknown preset \(pid).", hint: "Presets: " + RevenuePreset.all.map(\.id).joined(separator: ", "))
            }
            s = p.make(); headers = p.headers
        } else {
            let src = WidgetSourceType(rawValue: (o["source"] as? String) ?? "") ??
                (o["url"] != nil ? .http : o["command"] != nil ? .command : .push)
            s = CustomRevenue.makeSource(name: "Custom source", source: src)
        }
        if let v = o["name"] as? String, !v.isEmpty { s.name = v }
        if let v = o["url"] as? String { s.url = v }
        if let v = o["method"] as? String { s.method = v.uppercased() }
        if let v = o["body"] as? String { s.body = v }
        if let v = o["command"] as? String { s.command = v }
        if let v = o["transform"] as? String { s.transform = v }
        if let v = o["jsonPath"] as? String { s.jsonPath = v }
        if let v = o["enabled"] as? Bool { s.enabled = v }
        if let h = o["headers"] as? String { headers = h }
        else if let h = o["headers"] as? [String: Any] { headers = h.map { "\($0.key): \($0.value)" }.joined(separator: "\n") }
        if !headers.isEmpty { s.headers = headers }
        store.config.revenueSources.append(s)
        if s.source != .push { Task { await store.refresh(only: [.custom]) } }
        return revenueSourceJSON(s)
    }

    /// Body: {"source": id or name (created as a push source if missing), "rows": [...] | "data": <any JSON>}
    private func pushRevenue(_ o: [String: Any]) async throws -> [String: Any] {
        guard let ref = (o["source"] as? String)?.trimmingCharacters(in: .whitespaces), !ref.isEmpty else {
            throw APIError(400, "'source' (id or name) is required.")
        }
        guard let payload: Any = o["data"] ?? o["rows"].map({ rows -> Any in
            var d: [String: Any] = ["rows": rows]
            if let c = o["currency"] { d["currency"] = c }
            return d
        }) else { throw APIError(400, "Send 'rows' (array) or 'data' (any JSON).", hint: "GET /v1/revenue/format") }
        var src = store.config.revenueSources.first { $0.id == ref || $0.name.caseInsensitiveCompare(ref) == .orderedSame }
        if src == nil {
            src = CustomRevenue.makeSource(name: ref, source: .push)
            store.config.revenueSources.append(src!)
        }
        let s = src!
        guard s.source == .push else {
            throw APIError(400, "'\(s.name)' fetches its own data (\(s.source.rawValue)); push only works for push sources.")
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.fragmentsAllowed])
        let parsed: ProviderResult
        do {
            let value = try WidgetTransform.apply(s.transform, to: payload)
            parsed = try RevenueFormat.parse(s.jsonPath.isEmpty ? value : WidgetParser.select(value, path: s.jsonPath), sourceName: s.name)
        } catch {
            throw APIError(422, error.localizedDescription, hint: "GET /v1/revenue/format")
        }
        try data.write(to: CustomRevenue.pushPath(s.id))
        await store.refresh(only: [.custom])
        let dates = parsed.rows.map(\.date).sorted()
        return ["ok": true, "source": s.id, "name": s.name, "rows": parsed.rows.count,
                "apps": Array(Set(parsed.names.map(\.name))).sorted(),
                "from": dates.first ?? "", "to": dates.last ?? ""]
    }

    private func revenue(_ q: [String: String]) throws -> [String: Any] {
        var range = store.range
        if let r = q["range"], !r.isEmpty {
            guard let opt = DateRangeOption(rawValue: r.uppercased()) else {
                throw APIError(400, "'range' must be one of 7D, 30D, MTD, 90D.")
            }
            range = opt
        }
        let snap = store.snapshot(for: range)
        let includeSeries = q["series"].flatMap(Self.bool) ?? false
        func totals(_ t: Totals) -> [String: Any] {
            ["revenue": t.revenue, "adRevenue": t.adRevenue, "iapRevenue": t.iapRevenue, "spend": t.spend,
             "net": t.net, "roas": t.roas ?? NSNull(), "downloads": t.downloads, "impressions": t.impressions,
             "adImpressions": t.adImpressions, "clicks": t.clicks, "installs": t.installs]
        }
        func series(_ s: [DailyPoint]) -> [[String: Any]] {
            s.map { ["date": DayFormat.string($0.date), "revenue": $0.revenue, "spend": $0.spend, "net": $0.net] }
        }
        let (start, end) = range.dates()
        var out: [String: Any] = [
            "range": range.rawValue, "start": start, "end": end, "currency": store.config.baseCurrency,
            "totals": totals(snap.totals),
            "apps": snap.groups.map { g -> [String: Any] in
                var a: [String: Any] = ["id": g.id, "name": g.name, "platforms": g.platforms.map(\.rawValue),
                                        "storeIds": g.keys.map(\.id), "totals": totals(g.totals)]
                if includeSeries { a["series"] = series(g.series) }
                return a
            },
            "campaigns": snap.campaigns.map { c -> [String: Any] in
                ["id": c.id, "name": c.name, "source": c.source.rawValue, "app": c.appName ?? NSNull(),
                 "state": c.state.rawValue, "totals": totals(c.totals)]
            },
            "sources": store.configuredSources.map { k -> [String: Any] in
                let s = store.status[k] ?? .init()
                return ["source": k.rawValue, "lastSuccess": iso(s.lastSuccess), "error": s.error ?? NSNull(), "loading": s.loading]
            },
        ]
        if includeSeries { out["series"] = series(snap.series) }
        if !store.missingCurrencies.isEmpty { out["missingCurrencies"] = store.missingCurrencies }
        if !store.hasAnySource { out["note"] = "No revenue sources are configured. Connect them in SideStats Settings." }
        return out
    }

    // MARK: notify & panel

    private func notify(_ d: [String: Any]) async throws -> [String: Any] {
        guard let title = d["title"] as? String, !title.isEmpty else { throw APIError(400, "'title' is required.") }
        let body = (d["body"] as? String) ?? ""
        let subtitle = (d["subtitle"] as? String) ?? ""
        guard Bundle.main.bundleIdentifier != nil else {
            // Unbundled (development) builds can't use UserNotifications; fall back to AppleScript.
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "on run argv", "-e", "display notification (item 2 of argv) with title (item 1 of argv) subtitle (item 3 of argv)",
                           "-e", "end run", title, body, subtitle]
            try p.run()
            return ["ok": true, "via": "osascript"]
        }
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else {
            throw APIError(403, "Notifications are turned off for SideStats.", hint: "Enable them in System Settings → Notifications → SideStats.")
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if !subtitle.isEmpty { content.subtitle = subtitle }
        if (d["sound"] as? Bool) ?? true { content.sound = .default }
        try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        return ["ok": true]
    }

    private func panel(_ d: [String: Any]) throws -> [String: Any] {
        let action = ((d["action"] as? String) ?? "show").lowercased()
        guard ["show", "hide", "toggle", "pin", "unpin"].contains(action) else {
            throw APIError(400, "'action' must be one of show, hide, toggle, pin, unpin.")
        }
        guard let panelControl else { throw APIError(503, "The sidebar is not ready yet.") }
        var out = panelControl(action)
        out["ok"] = true
        return out
    }

    // MARK: helpers

    private static let isoFormatter = ISO8601DateFormatter()
    private func iso(_ d: Date?) -> Any { d.map { Self.isoFormatter.string(from: $0) } ?? NSNull() }

    static func encodeObject<T: Encodable>(_ v: T) -> [String: Any] {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        guard let d = try? e.encode(v), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return o
    }
}

// MARK: - HTTP plumbing

struct APIError: Error {
    var status: Int
    var message: String
    var hint: String?
    init(_ status: Int, _ message: String, hint: String? = nil) {
        self.status = status; self.message = message; self.hint = hint
    }
}

struct HTTPRequest {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data

    /// Any JSON value. Non-JSON bodies are returned as a string (handy for `curl --data-binary @file.txt`).
    func anyBody() throws -> Any {
        guard !body.isEmpty else { throw APIError(400, "Request body is empty; send JSON.") }
        if let j = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) { return j }
        let ct = headers["content-type"] ?? ""
        if ct.contains("json") { throw APIError(400, "Body is not valid JSON.") }
        return String(decoding: body, as: UTF8.self)
    }

    func object(allowEmpty: Bool = false) throws -> [String: Any] {
        if body.isEmpty || body.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) {
            if allowEmpty { return [:] }
            throw APIError(400, "Request body is empty; send a JSON object.")
        }
        guard let j = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) else {
            throw APIError(400, "Body is not valid JSON.")
        }
        guard let d = j as? [String: Any] else { throw APIError(400, "Body must be a JSON object.") }
        return d
    }
}

struct HTTPResponse {
    var status: Int
    var body: Data

    static func json(_ obj: Any, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, body: data)
    }

    static func error(_ status: Int, _ message: String, hint: String? = nil) -> HTTPResponse {
        var o: [String: Any] = ["error": message, "status": status]
        if let hint { o["hint"] = hint }
        return json(o, status: status)
    }

    static func reason(_ s: Int) -> String {
        switch s {
        case 200: return "OK"; case 201: return "Created"; case 400: return "Bad Request"
        case 401: return "Unauthorized"; case 403: return "Forbidden"; case 404: return "Not Found"
        case 405: return "Method Not Allowed"; case 408: return "Request Timeout"; case 413: return "Payload Too Large"
        case 422: return "Unprocessable Entity"; case 431: return "Request Header Fields Too Large"
        case 501: return "Not Implemented"; case 503: return "Service Unavailable"
        default: return "Error"
        }
    }
}

/// One request per connection: read headers + Content-Length body, respond, close.
@MainActor
private final class HTTPConnection {
    static let maxHeader = 32 * 1024
    static let maxBody = 8 * 1024 * 1024

    let conn: NWConnection
    weak var server: LocalAPIServer?
    var buffer = Data()
    var responded = false
    var sentContinue = false
    var timeout: DispatchWorkItem?

    init(_ conn: NWConnection, server: LocalAPIServer) {
        self.conn = conn
        self.server = server
    }

    func start() {
        conn.stateUpdateHandler = { [self] state in
            MainActor.assumeIsolated {
                switch state {
                case .failed, .cancelled: finish()
                default: break
                }
            }
        }
        conn.start(queue: .main)
        let t = DispatchWorkItem { [self] in
            MainActor.assumeIsolated { if !responded { respond(.error(408, "Timed out waiting for the request.")) } }
        }
        timeout = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: t)
        receive()
    }

    private func finish() {
        timeout?.cancel()
        conn.stateUpdateHandler = nil
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [self] data, _, complete, error in
            MainActor.assumeIsolated {
                guard !responded else { return }
                if let data { buffer.append(data) }
                switch parse() {
                case .incomplete:
                    if complete || error != nil { conn.cancel() } else { receive() }
                case .bad(let r):
                    respond(r)
                case .request(let req):
                    timeout?.cancel()
                    Task { @MainActor in
                        let r = await server?.handle(req) ?? .error(503, "Server stopped.")
                        respond(r)
                    }
                }
            }
        }
    }

    private enum ParseResult { case incomplete, bad(HTTPResponse), request(HTTPRequest) }

    private func parse() -> ParseResult {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > Self.maxHeader ? .bad(.error(431, "Headers too large.")) : .incomplete
        }
        let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard start.count == 3, start[2].hasPrefix("HTTP/1") else { return .bad(.error(400, "Malformed request line.")) }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let k = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[k] = headers[k].map { "\($0), \(v)" } ?? v
        }
        if headers["transfer-encoding"] != nil {
            return .bad(.error(501, "Chunked bodies are not supported; send Content-Length."))
        }
        guard let length = Int(headers["content-length"] ?? "0"), length >= 0 else {
            return .bad(.error(400, "Invalid Content-Length."))
        }
        if length > Self.maxBody { return .bad(.error(413, "Body larger than 8 MB.")) }
        let bodyStart = end.upperBound
        if buffer.endIndex - bodyStart < length {
            if headers["expect"]?.lowercased() == "100-continue" && !sentContinue {
                sentContinue = true
                conn.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .contentProcessed { _ in })
            }
            return .incomplete
        }
        let body = Data(buffer[bodyStart..<(bodyStart + length)])
        guard let comps = URLComponents(string: "http://localhost" + (start[1].hasPrefix("/") ? start[1] : "/" + start[1])) else {
            return .bad(.error(400, "Malformed path."))
        }
        var query: [String: String] = [:]
        for item in comps.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return .request(HTTPRequest(method: start[0].uppercased(), path: comps.path, query: query, headers: headers, body: body))
    }

    private func respond(_ r: HTTPResponse) {
        guard !responded else { return }
        responded = true
        timeout?.cancel()
        var head = "HTTP/1.1 \(r.status) \(HTTPResponse.reason(r.status))\r\n"
        head += "Content-Type: application/json; charset=utf-8\r\n"
        head += "Content-Length: \(r.body.count)\r\n"
        head += "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + r.body, contentContext: .finalMessage, isComplete: true,
                  completion: .contentProcessed { [conn] _ in conn.cancel() })
    }
}
