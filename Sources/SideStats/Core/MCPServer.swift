import Foundation

/// Compact reference of the widget format, shared by the MCP tools and `GET /v1/format`.
enum MCPDocs {
    static let widgetFormat = """
    SIDESTATS WIDGET FORMAT
    A widget is a card in the macOS sidebar. Sources:
    - push (default when no url/command): you send data with push_widget_data; it stays until you push again.
    - http: fetches url (method/body/headers) every refreshSeconds (min 5, default 300).
    - command: runs `/bin/zsh -lc <command>` every refreshSeconds; stdout is parsed (30 s timeout).
    Pipeline: payload -> transform (optional JS: `(data) => ({items:[...]})`) -> jsonPath -> explicit items (display=auto) or auto-detection.

    EXPLICIT ITEMS: send {"items":[...]}, a bare array of items, or one item. Unknown types are skipped.
    stat     {type:"stat", label, value:number|string, format:number|currency|percent|bytes|duration, currency:"USD",
              decimals, unit:"ms", delta:0.12 (fraction => ▲12%), positiveIsGood:true, caption, color, sparkline:[n,...]}
             percent values are fractions (0.25 = 25%); duration is seconds; bytes is raw bytes.
    chart    {type:"chart", label, kind:line|area|bar|pie|donut, points | series:[{name,color,points}], format, currency, height:110}
             points: [{x|date|label, y|value}] | [["2026-11-01",3],...] | [3,5,8]. If every x is a date
             (ISO-8601, yyyy-MM-dd, yyyy-MM, unix s/ms) the axis is a time axis. pie/donut use the first series.
    list     {type:"list", label, limit:10, rows:[{title, subtitle, value, valueColor, icon:"sf:star.fill"|"https://...png", url}]}
    text     {type:"text", text (Markdown in body style), style:title|body|caption|mono, color}
    progress {type:"progress", label, value:0..1 (or raw with max), max, caption, color}  (red above 90% unless color set)
    status   {type:"status", label, state:ok|warn|error|info (also up/down/healthy/degraded/fail/true/false), detail}
    colors: green red blue orange yellow purple pink teal gray primary secondary #RRGGBB
    Layout: consecutive stats form a grid (1 = full width, 3 = one row, otherwise 2 columns).

    AUTO-DETECTION of plain JSON (display=auto, no explicit items):
    42 -> stat labeled with the widget name | "text" -> text | true/false -> ok/error status
    [3,5,8] or [[x,y],...] -> line chart
    [{date|day|time|timestamp|ts|x|period|month|created_at|createdAt, n1, n2...}] -> chart, one series per numeric key (area if > 40 rows)
    [{title|name|label|key|id, <other string>, <number>}] -> list (title / first other string = subtitle / first number = value;
       icon|image|avatar_url = icon; url|html_url|link = click target)
    {users:120, plan:"pro", daily:[1,2], limits:{cpu:2}} -> stats for scalar keys (sorted, humanized labels), then nested
       arrays/objects up to 2 levels. Numeric strings ("59830.5") count as numbers.
    Shaping: jsonPath "data.items" / "result.0" / "items.-1"; fields "k1,k2" keeps only those keys in that order;
    display stat|chart|list|text forces a layout (explicit items are only used with display=auto).

    PLACEHOLDERS in url/body/command (UTC yyyy-MM-dd): {{today}} {{daysAgo:N}} {{monthStart}}
    HEADERS: "Name: value" per line (or an object); stored in the macOS Keychain, never exported.

    TIPS: build dashboards with explicit items + push. Use http + jsonPath/fields for existing JSON APIs and
    command for local scripts (e.g. `df -k / | awk ...` printing JSON). Keep cards small: 2-4 stats, one chart, short lists.

    EXAMPLE push payload:
    {"items":[{"type":"stat","label":"MRR","value":12840,"format":"currency","delta":0.12,"sparkline":[9800,11500,12840]},
     {"type":"stat","label":"Churn","value":0.031,"format":"percent","positiveIsGood":false},
     {"type":"chart","label":"Signups","kind":"bar","points":[["2026-11-20",12],["2026-11-21",18]]},
     {"type":"status","label":"API","state":"ok","detail":"99.98%"}]}
    """
}

/// `SideStats --mcp`: a stdio MCP server (JSON-RPC 2.0, newline-delimited) that bridges to the local
/// HTTP API of the running app, launching the app when needed. Only protocol messages go to stdout.
enum MCPServer {
    static let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    static let defaultVersion = "2025-06-18"

    static func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        log("SideStats MCP server \(AppVersion.string) ready (stdio)")
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            guard let msg = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) else {
                send(errorResponse(NSNull(), -32700, "Parse error: invalid JSON"))
                continue
            }
            if let batch = msg as? [Any] {
                if batch.isEmpty { send(errorResponse(NSNull(), -32600, "Invalid Request: empty batch")); continue }
                let out = batch.compactMap(handle)
                if !out.isEmpty { send(out) }
            } else if let r = handle(msg) {
                send(r)
            }
        }
        exit(0)
    }

    // MARK: JSON-RPC

    static func log(_ s: String) {
        FileHandle.standardError.write(Data("[sidestats-mcp] \(s)\n".utf8))
    }

    private static func send(_ obj: Any) {
        guard var d = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return }
        d.append(0x0A)
        FileHandle.standardOutput.write(d)
    }

    private static func errorResponse(_ id: Any, _ code: Int, _ message: String, data: Any? = nil) -> [String: Any] {
        var e: [String: Any] = ["code": code, "message": message]
        if let data { e["data"] = data }
        return ["jsonrpc": "2.0", "id": id, "error": e]
    }

    private static func result(_ id: Any, _ r: Any) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": r]
    }

    /// Returns the response, or nil for notifications / client responses.
    static func handle(_ msg: Any) -> [String: Any]? {
        guard let m = msg as? [String: Any] else { return errorResponse(NSNull(), -32600, "Invalid Request: expected an object") }
        let hasId = m.keys.contains("id")
        let id: Any = m["id"] ?? NSNull()
        let isNumber = (id as? NSNumber).map { CFGetTypeID($0) != CFBooleanGetTypeID() } ?? false
        if hasId, !(id is String || isNumber || id is NSNull) {
            return errorResponse(NSNull(), -32600, "Invalid Request: id must be a string or number")
        }
        guard (m["jsonrpc"] as? String) == "2.0" else {
            return hasId ? errorResponse(id, -32600, "Invalid Request: jsonrpc must be \"2.0\"") : nil
        }
        guard let method = m["method"] as? String else {
            if m["result"] != nil || m["error"] != nil { return nil }   // a response to us; we never send requests
            return errorResponse(id, -32600, "Invalid Request: missing method")
        }
        if let p = m["params"], !(p is [String: Any]) && !(p is [Any]) {
            return hasId ? errorResponse(id, -32602, "Invalid params: params must be an object") : nil
        }
        let params = (m["params"] as? [String: Any]) ?? [:]
        guard hasId else { return nil }   // notifications/initialized, notifications/cancelled, …

        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            let version = supportedVersions.contains(requested) ? requested : defaultVersion
            return result(id, [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "sidestats", "title": "SideStats", "version": AppVersion.string],
                "instructions": """
                SideStats is a macOS sidebar of modules: Apps & Revenue, Tasks, and custom widgets. \
                Create widgets with create_widget (source push + push_widget_data for data you compute, http for JSON APIs, \
                command for local scripts) and render them with the SideStats item format (call get_widget_format once for details). \
                Manage tasks with add_task / list_tasks / complete_task. Read app revenue with get_revenue.
                """,
            ])
        case "ping":
            return result(id, [String: Any]())
        case "tools/list":
            return result(id, ["tools": MCPTools.all.map(\.definition)])
        case "tools/call":
            guard let name = params["name"] as? String else { return errorResponse(id, -32602, "Invalid params: missing tool name") }
            guard let tool = MCPTools.all.first(where: { $0.name == name }) else {
                return errorResponse(id, -32602, "Unknown tool: \(name)")
            }
            let args: [String: Any]
            if let a = params["arguments"] {
                guard let d = a as? [String: Any] else { return errorResponse(id, -32602, "Invalid params: arguments must be an object") }
                args = d
            } else { args = [:] }
            return result(id, tool.call(args))
        default:
            return errorResponse(id, -32601, "Method not found: \(method)")
        }
    }
}

// MARK: - Tools

struct MCPTool {
    var name: String
    var title: String
    var description: String
    var properties: [String: Any] = [:]
    var required: [String] = []
    var readOnly = false
    var destructive = false
    var idempotent = false
    var run: ([String: Any]) throws -> Any

    var definition: [String: Any] {
        [
            "name": name, "title": title, "description": description,
            "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false] as [String: Any],
            "annotations": ["title": title, "readOnlyHint": readOnly, "destructiveHint": destructive,
                            "idempotentHint": idempotent, "openWorldHint": false],
        ]
    }

    func call(_ args: [String: Any]) -> [String: Any] {
        do {
            try validate(args)
            let out = try run(args)
            let text: String
            if let s = out as? String { text = s }
            else if let d = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys, .withoutEscapingSlashes]) {
                text = String(decoding: d, as: UTF8.self)
            } else { text = "\(out)" }
            return ["content": [["type": "text", "text": text]], "isError": false]
        } catch {
            return ["content": [["type": "text", "text": "Error: \(error.localizedDescription)"]], "isError": true]
        }
    }

    /// Light JSON-schema check: required keys, unknown keys, primitive types and enums.
    private func validate(_ args: [String: Any]) throws {
        let missing = required.filter { args[$0] == nil || args[$0] is NSNull }
        if !missing.isEmpty { throw SideStatsError("Missing required argument(s): \(missing.joined(separator: ", ")).") }
        let unknown = args.keys.filter { properties[$0] == nil }.sorted()
        if !unknown.isEmpty {
            throw SideStatsError("Unknown argument(s): \(unknown.joined(separator: ", ")). Allowed: \(properties.keys.sorted().joined(separator: ", ")).")
        }
        for (k, v) in args {
            guard let schema = properties[k] as? [String: Any], !(v is NSNull) else { continue }
            let types: [String] = (schema["type"] as? [String]) ?? ((schema["type"] as? String).map { [$0] } ?? [])
            if !types.isEmpty && !types.contains(where: { Self.matches(v, $0) }) {
                throw SideStatsError("Argument '\(k)' must be \(types.joined(separator: " or ")).")
            }
            if let allowed = schema["enum"] as? [String], let s = v as? String, !allowed.contains(s) {
                throw SideStatsError("Argument '\(k)' must be one of: \(allowed.joined(separator: ", ")).")
            }
        }
    }

    private static func matches(_ v: Any, _ type: String) -> Bool {
        let isBool = (v as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
        switch type {
        case "string": return v is String
        case "boolean": return isBool
        case "integer": return !isBool && (v as? NSNumber).map { $0.doubleValue.rounded() == $0.doubleValue } == true
        case "number": return !isBool && v is NSNumber
        case "array": return v is [Any]
        case "object": return v is [String: Any]
        case "null": return v is NSNull
        default: return true
        }
    }
}

enum MCPTools {
    // Schema helpers
    private static func str(_ d: String, _ e: [String]? = nil) -> [String: Any] {
        var s: [String: Any] = ["type": "string", "description": d]
        if let e { s["enum"] = e }
        return s
    }
    private static func int(_ d: String, min: Int? = nil, max: Int? = nil) -> [String: Any] {
        var s: [String: Any] = ["type": "integer", "description": d]
        if let min { s["minimum"] = min }
        if let max { s["maximum"] = max }
        return s
    }
    private static func bool(_ d: String) -> [String: Any] { ["type": "boolean", "description": d] }
    private static func strings(_ d: String) -> [String: Any] { ["type": "array", "items": ["type": "string"], "description": d] }
    private static let anyJSON: [String: Any] = [
        "type": ["object", "array", "string", "number", "boolean"],
        "description": "The payload to render: SideStats items ({\"items\":[{\"type\":\"stat\",…}]}) or any plain JSON (auto-detected). Pass a JSON value, not a JSON-encoded string.",
    ]

    private static let itemsCheatSheet = """
    Data format (push payloads and http/command output): {"items":[…]} with item types: \
    stat {label,value,format:number|currency|percent(0.25=25%)|bytes|duration(s),currency,unit,delta(0.12=▲12%),positiveIsGood,caption,color,sparkline:[n]}; \
    chart {label,kind:line|area|bar|pie|donut,points:[[x,y]]|[{x,y}]|[n],series:[{name,color,points}],format}; \
    list {label,limit,rows:[{title,subtitle,value,valueColor,icon:"sf:symbol"|url,url}]}; \
    text {text(markdown),style:title|body|caption|mono}; progress {label,value(0..1 or with max),max,caption}; \
    status {label,state:ok|warn|error|info,detail}. Colors: green red blue orange yellow purple pink teal gray or #RRGGBB. \
    Plain JSON is auto-detected (number→stat, number array→chart, rows with a date key→chart, other arrays→list, object→stat grid). \
    Call get_widget_format for the full reference.
    """

    private static var widgetFields: [String: Any] {
        [
            "name": str("Card title, e.g. \"Stripe MRR\"."),
            "icon": str("SF Symbol name for the card header, e.g. chart.line.uptrend.xyaxis, server.rack, dollarsign.circle, bitcoinsign.circle, cpu, checkmark.seal."),
            "source": str("push = you send data with push_widget_data (default when no url/command). http = SideStats fetches url on a timer. command = runs a zsh command on a timer and parses stdout.", ["push", "http", "command"]),
            "url": str("http: URL returning JSON. Placeholders {{today}}, {{daysAgo:N}}, {{monthStart}} (UTC yyyy-MM-dd)."),
            "method": str("http: HTTP method (default GET).", ["GET", "POST", "PUT", "PATCH", "DELETE"]),
            "body": str("http: request body (JSON text). Placeholders are expanded."),
            "headers": ["type": ["string", "object"], "description": "http: request headers, either \"Name: value\" lines or an object {\"Authorization\": \"Bearer …\"}. Stored in the macOS Keychain, never exported."] as [String: Any],
            "command": str("command: shell command run with /bin/zsh -lc (login PATH). Print JSON (SideStats items or plain) or text to stdout. 30 s timeout."),
            "jsonPath": str("Dot path applied to the response before rendering: data, data.items, result.0, items.-1."),
            "fields": str("Comma-separated keys to keep (in that order) when auto-rendering an object as stats, e.g. \"stargazers_count,forks_count\"."),
            "display": str("Force a layout. auto (default) uses explicit items or auto-detection.", ["auto", "stat", "chart", "list", "text"]),
            "refreshSeconds": int("http/command: refresh interval in seconds (min 5, default 300). ≤ 60 shows a live dot.", min: 5, max: 86400),
            "enabled": bool("Disabled widgets are hidden and not fetched."),
            "transform": str("Optional JavaScript run on the payload before rendering: `(data) => ({items:[…]})` or a body using `data` that returns a value."),
        ]
    }

    private static func id(_ what: String) -> [String: Any] { str("\(what) id (from list_modules / list_tasks).") }

    private static func pathID(_ a: [String: Any], _ key: String = "id") throws -> String {
        guard let v = a[key] as? String, !v.isEmpty else { throw SideStatsError("'\(key)' is required.") }
        return v.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? v
    }

    /// Some clients send nested JSON as a string; decode it when it clearly is JSON.
    private static func jsonValue(_ v: Any) -> Any {
        guard let s = v as? String else { return v }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("{") || t.hasPrefix("["),
              let j = try? JSONSerialization.jsonObject(with: Data(t.utf8)) else { return v }
        return j
    }

    static let all: [MCPTool] = [
        MCPTool(name: "sidestats_status", title: "SideStats status",
                description: "Check that SideStats is running (launches it if needed) and get its version, API port and counts of modules, widgets, tasks and revenue apps.",
                readOnly: true, idempotent: true) { _ in try API.call("GET", "/v1/status") },

        MCPTool(name: "list_modules", title: "List sidebar modules",
                description: "List all sidebar modules in display order: built-ins (builtin.revenue = Apps & Revenue, builtin.tasks = Tasks) and widgets, with id, title, kind, hidden/collapsed/enabled, and for widgets source, refreshSeconds, last update, error and rendered item count. Use the ids with the other tools.",
                readOnly: true, idempotent: true) { _ in try API.call("GET", "/v1/modules") },

        MCPTool(name: "get_widget_format", title: "Widget format reference",
                description: "Return the complete SideStats widget format reference (item types and fields, chart point forms, auto-detection rules for plain JSON, jsonPath/fields/display, placeholders) plus an example. Read it before building a non-trivial widget.",
                readOnly: true, idempotent: true) { _ in MCPDocs.widgetFormat },

        MCPTool(name: "create_widget", title: "Create widget",
                description: """
                Create a sidebar widget and return it (with its id). Three sources: \
                push (default; then send data with push_widget_data, or pass `data` here to render immediately), \
                http (SideStats fetches `url` every refreshSeconds; use jsonPath/fields to shape plain JSON, headers for auth), \
                command (zsh command whose stdout is JSON or text). \(itemsCheatSheet)
                """,
                properties: widgetFields.merging(["data": anyJSON]) { a, _ in a }, required: ["name"]) { a in
            var body = a
            if let d = a["data"] { body["data"] = jsonValue(d) }
            return try API.call("POST", "/v1/widgets", body: body)
        },

        MCPTool(name: "update_widget", title: "Update widget",
                description: "Change any fields of an existing widget (only the fields you pass are changed). Changing url/command/source refetches; changing display/jsonPath/fields re-renders the cached data. Pass `data` to push new data at the same time.",
                properties: widgetFields.merging(["id": id("Widget"), "data": anyJSON]) { a, _ in a }, required: ["id"],
                idempotent: true) { a in
            var body = a
            body["id"] = nil
            if let d = a["data"] { body["data"] = jsonValue(d) }
            return try API.call("PATCH", "/v1/widgets/\(try pathID(a))", body: body)
        },

        MCPTool(name: "delete_widget", title: "Delete widget",
                description: "Permanently delete a widget (its config, cached data and stored headers).",
                properties: ["id": id("Widget")], required: ["id"], destructive: true, idempotent: true) { a in
            try API.call("DELETE", "/v1/widgets/\(try pathID(a))")
        },

        MCPTool(name: "push_widget_data", title: "Push widget data",
                description: "Replace what a widget shows with new data (typically a push widget). The payload is rendered right away and kept across restarts. Returns the rendered item count and types — if 0 items, fix the payload. \(itemsCheatSheet)",
                properties: ["id": id("Widget"), "data": anyJSON], required: ["id", "data"], idempotent: true) { a in
            try API.call("POST", "/v1/widgets/\(try pathID(a))/data", body: jsonValue(a["data"]!))
        },

        MCPTool(name: "refresh_widget", title: "Refresh widget",
                description: "Fetch an http/command widget now and wait for the result (up to ~35 s). Returns the widget state including any fetch error. Push widgets can't be refreshed; push data instead.",
                properties: ["id": id("Widget")], required: ["id"], idempotent: true) { a in
            try API.call("POST", "/v1/widgets/\(try pathID(a))/refresh", timeout: 45)
        },

        MCPTool(name: "reorder_modules", title: "Reorder modules",
                description: "Reorder sidebar modules. Either pass `order` (module ids to put first, in that order; unlisted modules keep their relative order after them) or `move` one module to a 0-based index with `id` + `to`.",
                properties: ["order": strings("Module ids in the desired top-to-bottom order."),
                             "id": str("Module id to move (with `to`)."),
                             "to": int("Target 0-based position for `id`.", min: 0)],
                idempotent: true) { a in
            var body: [String: Any] = [:]
            if let o = a["order"] { body["order"] = o }
            if let i = a["id"] as? String {
                guard let to = a["to"] else { throw SideStatsError("'to' is required with 'id'.") }
                body["move"] = ["id": i, "to": to]
            }
            if body.isEmpty { throw SideStatsError("Pass 'order' or 'id' + 'to'.") }
            return try API.call("POST", "/v1/layout", body: body)
        },

        MCPTool(name: "set_module_visibility", title: "Show / hide / collapse modules",
                description: "Hide or show modules in the sidebar, and/or collapse or expand them. Works for built-ins (builtin.revenue, builtin.tasks) and widgets. Hidden modules keep their data.",
                properties: ["ids": strings("Module ids to change."),
                             "hidden": bool("true hides, false shows."),
                             "collapsed": bool("true collapses to the header, false expands.")],
                required: ["ids"], idempotent: true) { a in
            let ids = (a["ids"] as? [String]) ?? []
            var body: [String: Any] = [:]
            if let h = a["hidden"] as? Bool { body[h ? "hide" : "show"] = ids }
            if let c = a["collapsed"] as? Bool { body[c ? "collapse" : "expand"] = ids }
            if body.isEmpty { throw SideStatsError("Pass 'hidden' and/or 'collapsed'.") }
            return try API.call("POST", "/v1/layout", body: body)
        },

        MCPTool(name: "list_integrations", title: "List integrations",
                description: "List ready-made integrations (presets such as monitoring, dev and business services) with their id, summary and required parameters. Add one with add_integration.",
                readOnly: true, idempotent: true) { _ in try API.call("GET", "/v1/presets") },

        MCPTool(name: "add_integration", title: "Add integration",
                description: "Create a widget from a ready-made integration. `params` maps the integration's parameter ids (from list_integrations) to values; secret parameters are stored in the Keychain.",
                properties: ["preset": str("Integration id from list_integrations."),
                             "params": ["type": "object", "additionalProperties": ["type": "string"], "description": "Parameter values by parameter id."] as [String: Any],
                             "name": str("Optional card title override."),
                             "refreshSeconds": int("Optional refresh interval override (seconds).", min: 5)],
                required: ["preset"]) { a in
            var body: [String: Any] = ["params": a["params"] ?? [String: Any]()]
            if let n = a["name"] { body["name"] = n }
            if let r = a["refreshSeconds"] { body["refreshSeconds"] = r }
            return try API.call("POST", "/v1/presets/\(try pathID(a, "preset"))", body: body)
        },

        MCPTool(name: "list_tasks", title: "List tasks",
                description: "List tasks from the SideStats Tasks module (id, title, notes, due, done, priority 0-3, list, overdue).",
                properties: ["include_done": bool("Include completed tasks (default false)."),
                             "list": str("Only tasks in this list, e.g. Inbox.")],
                readOnly: true, idempotent: true) { a in
            var q = [String]()
            if (a["include_done"] as? Bool) != true { q.append("done=false") }
            if let l = a["list"] as? String { q.append("list=" + (l.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+"))) ?? l)) }
            return try API.call("GET", "/v1/todos" + (q.isEmpty ? "" : "?" + q.joined(separator: "&")))
        },

        MCPTool(name: "add_task", title: "Add task",
                description: "Add a task / reminder to the SideStats Tasks module.",
                properties: ["title": str("What to do."),
                             "notes": str("Optional details."),
                             "due": str("Optional due date: yyyy-MM-dd (all day, local time) or ISO-8601 with time, e.g. 2026-11-26T15:00:00+01:00."),
                             "priority": ["type": ["string", "integer"], "description": "Optional priority none|low|medium|high or 0-3."] as [String: Any],
                             "list": str("Optional list name (default Inbox).")],
                required: ["title"]) { a in try API.call("POST", "/v1/todos", body: a) },

        MCPTool(name: "update_task", title: "Update task",
                description: "Change a task's title, notes, due date (empty string clears it), priority, list or done state. Only passed fields change.",
                properties: ["id": id("Task"), "title": str("New title."), "notes": str("New notes."),
                             "due": str("yyyy-MM-dd or ISO-8601; empty string removes the due date."),
                             "priority": ["type": ["string", "integer"], "description": "Priority none|low|medium|high or 0-3."] as [String: Any],
                             "list": str("List name."), "done": bool("Completed state.")],
                required: ["id"], idempotent: true) { a in
            var body = a
            body["id"] = nil
            return try API.call("PATCH", "/v1/todos/\(try pathID(a))", body: body)
        },

        MCPTool(name: "complete_task", title: "Complete task",
                description: "Mark a task as done (or not done with done=false).",
                properties: ["id": id("Task"), "done": bool("Default true.")], required: ["id"], idempotent: true) { a in
            try API.call("PATCH", "/v1/todos/\(try pathID(a))", body: ["done": (a["done"] as? Bool) ?? true])
        },

        MCPTool(name: "delete_task", title: "Delete task",
                description: "Permanently delete a task.",
                properties: ["id": id("Task")], required: ["id"], destructive: true, idempotent: true) { a in
            try API.call("DELETE", "/v1/todos/\(try pathID(a))")
        },

        MCPTool(name: "get_revenue", title: "Get app revenue",
                description: "Revenue, ad revenue, in-app revenue, ad spend, net, ROAS and downloads for the user's apps (App Store, Google Play, AdMob, Search Ads, Meta), as totals and per app, converted to the base currency. Data comes from the sources configured in SideStats.",
                properties: ["range": str("Date range (default: the one selected in the sidebar).", ["7D", "30D", "MTD", "90D"]),
                             "include_series": bool("Include daily revenue/spend series (default false).")],
                readOnly: true, idempotent: true) { a in
            var q = [String]()
            if let r = a["range"] as? String { q.append("range=\(r)") }
            if (a["include_series"] as? Bool) == true { q.append("series=true") }
            return try API.call("GET", "/v1/revenue" + (q.isEmpty ? "" : "?" + q.joined(separator: "&")))
        },

        MCPTool(name: "notify", title: "Show notification",
                description: "Show a macOS notification from SideStats (e.g. when a long task finishes).",
                properties: ["title": str("Notification title."), "body": str("Notification text."),
                             "subtitle": str("Optional subtitle.")],
                required: ["title"]) { a in try API.call("POST", "/v1/notify", body: a) },

        MCPTool(name: "show_panel", title: "Show / hide sidebar",
                description: "Show, hide or toggle the SideStats sidebar, or pin it open / unpin it. Use show after creating widgets so the user sees them.",
                properties: ["action": str("Default show.", ["show", "hide", "toggle", "pin", "unpin"])],
                idempotent: true) { a in
            try API.call("POST", "/v1/panel", body: ["action": (a["action"] as? String) ?? "show"])
        },
    ]
}

// MARK: - Local API client (used by the MCP process)

enum API {
    private static var launched = false

    static func call(_ method: String, _ path: String, body: Any? = nil, timeout: TimeInterval = 20) throws -> Any {
        var info = LocalAPIInfo.read()
        if info == nil { info = try launchAndWait() }
        do {
            return try send(method, path, body: body, info: info!, timeout: timeout)
        } catch let e as ConnectionError {
            switch e {
            case .unreachable:
                let fresh = try launchAndWait()
                return try send(method, path, body: body, info: fresh, timeout: timeout)
            case .unauthorized:
                // Token regenerated or a new instance on another port: re-read once.
                guard let fresh = LocalAPIInfo.read() else { throw SideStatsError("SideStats rejected the token. Check Settings → API & MCP.") }
                return try send(method, path, body: body, info: fresh, timeout: timeout)
            }
        }
    }

    private enum ConnectionError: Error { case unreachable, unauthorized }

    private static func send(_ method: String, _ path: String, body: Any?, info: LocalAPIInfo, timeout: TimeInterval) throws -> Any {
        guard let url = URL(string: "http://127.0.0.1:\(info.port)\(path)") else { throw SideStatsError("Bad path \(path)") }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("Bearer \(info.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.fragmentsAllowed])
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var out: (Data?, URLResponse?, Error?)
        let task = URLSession.shared.dataTask(with: req) { d, r, e in out = (d, r, e); sem.signal() }
        task.resume()
        sem.wait()
        if let e = out.2 as? URLError {
            switch e.code {
            case .cannotConnectToHost, .networkConnectionLost, .cannotFindHost, .notConnectedToInternet:
                throw ConnectionError.unreachable
            default: throw SideStatsError("SideStats API request failed: \(e.localizedDescription)")
            }
        }
        if let e = out.2 { throw e }
        let status = (out.1 as? HTTPURLResponse)?.statusCode ?? 0
        let data = out.0 ?? Data()
        let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        if status == 401 { throw ConnectionError.unauthorized }
        guard (200..<300).contains(status) else {
            let d = json as? [String: Any]
            var msg = (d?["error"] as? String) ?? "HTTP \(status)"
            if let hint = d?["hint"] as? String { msg += " (\(hint))" }
            throw SideStatsError(msg)
        }
        return json ?? String(decoding: data, as: UTF8.self)
    }

    private static func ping(_ info: LocalAPIInfo) -> Bool {
        (try? send("GET", "/v1/status", body: nil, info: info, timeout: 1.5)) != nil
    }

    /// Starts SideStats (bundle of this executable, then the installed app, then this binary itself)
    /// and waits up to ~12 s for its API.
    private static func launchAndWait() throws -> LocalAPIInfo {
        if let info = LocalAPIInfo.read(), ping(info) { return info }
        if !launched {
            launched = true
            launchApp()
        }
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            if let info = LocalAPIInfo.read(), ping(info) { return info }
            Thread.sleep(forTimeInterval: 0.3)
        }
        launched = false
        throw SideStatsError("SideStats is not running and could not be started (no API at \(LocalAPIInfo.fileURL.path)). Open SideStats.app, then check Settings → API & MCP.")
    }

    private static func launchApp() {
        let exe = AppVersion.executablePath
        if let r = exe.range(of: ".app/Contents/MacOS/") {
            let bundle = String(exe[..<r.lowerBound]) + ".app"
            MCPServer.log("launching \(bundle)")
            if runOpen(["-g", "-j", bundle]) { return }
        } else {
            // Unbundled (development) binary: start this executable as the app, detached from our session.
            MCPServer.log("launching \(exe)")
            if spawnDetached(exe) { return }
        }
        MCPServer.log("launching bundle id app.sidestats.SideStats")
        _ = runOpen(["-g", "-b", "app.sidestats.SideStats"])
    }

    private static func runOpen(_ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
    }

    private static func spawnDetached(_ path: String) -> Bool {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
        var fa: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }
        posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&fa, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_WRONLY, 0)
        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(path), nil]
        defer { argv.forEach { free($0) } }
        return posix_spawn(&pid, path, &fa, &attr, argv, environ) == 0
    }
}
