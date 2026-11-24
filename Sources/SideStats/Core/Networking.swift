import Compression
import Foundation

enum HTTP {
    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 60
        c.httpAdditionalHeaders = ["User-Agent": "SideStats/1.0 (macOS)"]
        return URLSession(configuration: c)
    }()

    @discardableResult
    static func data(_ req: URLRequest, allow404: Bool = false) async throws -> (Data, Int) {
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 && allow404 { return (data, code) }
        guard (200..<300).contains(code) else {
            let body = String(data: data.prefix(600), encoding: .utf8) ?? ""
            throw SideStatsError("HTTP \(code) from \(req.url?.host ?? "?"): \(body)")
        }
        return (data, code)
    }

    static func json(_ req: URLRequest) async throws -> Any {
        let (d, _) = try await data(req)
        return try JSONSerialization.jsonObject(with: d)
    }

    static func request(_ url: String, method: String = "GET", bearer: String? = nil,
                        json body: Any? = nil, form: [String: String]? = nil,
                        headers: [String: String] = [:]) -> URLRequest {
        var r = URLRequest(url: URL(string: url)!)
        r.httpMethod = method
        if let bearer { r.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        if let body {
            r.httpBody = try? JSONSerialization.data(withJSONObject: body)
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let form {
            r.httpBody = Data(formEncode(form).utf8)
            r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        return r
    }

    static func formEncode(_ dict: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return dict.map { k, v in
            "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)"
        }.joined(separator: "&")
    }
}

/// Small JSON navigation helpers for untyped API responses.
extension Dictionary where Key == String, Value == Any {
    func str(_ k: String) -> String? {
        if let s = self[k] as? String { return s }
        if let n = self[k] as? NSNumber { return n.stringValue }
        return nil
    }
    func dict(_ k: String) -> [String: Any]? { self[k] as? [String: Any] }
    func arr(_ k: String) -> [[String: Any]] { self[k] as? [[String: Any]] ?? [] }
    func num(_ k: String) -> Double {
        if let n = self[k] as? NSNumber { return n.doubleValue }
        if let s = self[k] as? String { return Double(s) ?? 0 }
        return 0
    }
}

enum Gzip {
    /// Decompresses a gzip stream (RFC 1952) using the system Compression framework.
    static func decompress(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count > 18, bytes[0] == 0x1f, bytes[1] == 0x8b else { return data }
        let flags = bytes[3]
        var idx = 10
        if flags & 0x04 != 0 { idx += 2 + Int(bytes[idx]) + Int(bytes[idx + 1]) << 8 }
        if flags & 0x08 != 0 { while idx < bytes.count && bytes[idx] != 0 { idx += 1 }; idx += 1 }
        if flags & 0x10 != 0 { while idx < bytes.count && bytes[idx] != 0 { idx += 1 }; idx += 1 }
        if flags & 0x02 != 0 { idx += 2 }
        let deflated = Array(bytes[idx..<(bytes.count - 8)])
        let isize = Int(bytes[bytes.count - 4]) | Int(bytes[bytes.count - 3]) << 8
            | Int(bytes[bytes.count - 2]) << 16 | Int(bytes[bytes.count - 1]) << 24
        var capacity = max(isize, deflated.count * 4, 64 * 1024)
        while true {
            var out = [UInt8](repeating: 0, count: capacity)
            let n = compression_decode_buffer(&out, capacity, deflated, deflated.count, nil, COMPRESSION_ZLIB)
            if n == 0 { throw SideStatsError("gzip decode failed") }
            if n < capacity { return Data(out.prefix(n)) }
            capacity *= 4
        }
    }
}

enum CSV {
    /// RFC 4180-ish parser supporting quotes and a custom delimiter.
    static func parse(_ text: String, delimiter: Character = ",") -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var it = text.makeIterator()
        var pending: Character?
        while let c = pending ?? it.next() {
            pending = nil
            if inQuotes {
                if c == "\"" {
                    if let n = it.next() {
                        if n == "\"" { field.append("\"") } else { inQuotes = false; pending = n }
                    } else { inQuotes = false }
                } else { field.append(c) }
            } else if c == "\"" {
                inQuotes = true
            } else if c == delimiter {
                row.append(field); field = ""
            } else if c == "\n" || c == "\r\n" || c == "\r" {
                row.append(field); field = ""
                if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                row = []
            } else {
                field.append(c)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    /// Parses with a header row into dictionaries keyed by trimmed header name.
    static func records(_ text: String, delimiter: Character = ",") -> [[String: String]] {
        let rows = parse(text, delimiter: delimiter)
        guard let header = rows.first?.map({ $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\u{feff}", with: "") }) else { return [] }
        return rows.dropFirst().map { r in
            var d: [String: String] = [:]
            for (i, h) in header.enumerated() where i < r.count { d[h] = r[i] }
            return d
        }
    }

    static func decode(_ data: Data) -> String {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16) ?? ""
        }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }
}

/// Currency conversion with ECB reference rates (frankfurter.dev, no API key, no user data sent).
actor FXService {
    static let shared = FXService()
    private var rates: [String: [String: Double]] = [:]   // base -> (currency -> rate)
    private var fetchedAt: [String: Date] = [:]

    func rates(base: String) async -> [String: Double] {
        if let r = rates[base], let t = fetchedAt[base], Date().timeIntervalSince(t) < 6 * 3600 { return r }
        let cacheURL = Storage.dir.appendingPathComponent("fx-\(base).json")
        do {
            let json = try await HTTP.json(HTTP.request("https://api.frankfurter.dev/v1/latest?base=\(base)")) as? [String: Any]
            var r = (json?["rates"] as? [String: Double]) ?? [:]
            r[base] = 1
            rates[base] = r; fetchedAt[base] = Date()
            try? JSONEncoder().encode(r).write(to: cacheURL)
            return r
        } catch {
            if let d = try? Data(contentsOf: cacheURL), let r = try? JSONDecoder().decode([String: Double].self, from: d) {
                rates[base] = r; fetchedAt[base] = Date()
                return r
            }
            return [base: 1]
        }
    }
}

enum Storage {
    static let dir: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SideStats", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    static func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }

    static func save<T: Encodable>(_ value: T, _ name: String) {
        try? JSONEncoder().encode(value).write(to: dir.appendingPathComponent(name), options: .atomic)
    }

    static func remove(_ name: String) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
    }
}
