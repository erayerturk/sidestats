import AppKit
import CryptoKit
import Foundation
import Network

/// OAuth 2.0 for installed apps (loopback redirect + PKCE). Users bring their own
/// "Desktop app" OAuth client from Google Cloud, so no shared secrets ship with SideStats.
actor GoogleOAuth {
    static let shared = GoogleOAuth()
    static let scopes = [
        "https://www.googleapis.com/auth/admob.readonly",
        "https://www.googleapis.com/auth/devstorage.read_only",
    ]

    private var accessToken: String?
    private var expiresAt = Date.distantPast

    func accessToken(clientId: String) async throws -> String {
        if let t = accessToken, expiresAt.timeIntervalSinceNow > 60 { return t }
        guard let refresh = Secret.googleRefreshToken.value, let secret = Secret.googleClientSecret.value else {
            throw SideStatsError("Google is not connected. Open Settings → Google → Sign in.")
        }
        let json = try await HTTP.json(HTTP.request("https://oauth2.googleapis.com/token", method: "POST", form: [
            "client_id": clientId, "client_secret": secret,
            "refresh_token": refresh, "grant_type": "refresh_token",
        ])) as? [String: Any] ?? [:]
        guard let token = json.str("access_token") else { throw SideStatsError("Google token refresh failed") }
        accessToken = token
        expiresAt = Date().addingTimeInterval(json.num("expires_in"))
        return token
    }

    func signOut() {
        accessToken = nil
        Secret.googleRefreshToken.set(nil)
    }

    /// Runs the interactive browser sign-in and stores the refresh token.
    func signIn(clientId: String, clientSecret: String) async throws {
        let verifier = JWT.base64url(Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
        let challenge = JWT.base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = UUID().uuidString

        let receiver = try LoopbackReceiver()
        let port = try await receiver.start()
        let redirect = "http://127.0.0.1:\(port)"

        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            .init(name: "client_id", value: clientId),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: Self.scopes.joined(separator: " ")),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
            .init(name: "state", value: state),
        ]
        let authURL = comps.url!
        await MainActor.run { _ = NSWorkspace.shared.open(authURL) }

        let params = try await receiver.waitForCallback(timeout: 300)
        guard params["state"] == state else { throw SideStatsError("OAuth state mismatch") }
        guard let code = params["code"] else {
            throw SideStatsError("Google sign-in was cancelled (\(params["error"] ?? "no code"))")
        }
        let json = try await HTTP.json(HTTP.request("https://oauth2.googleapis.com/token", method: "POST", form: [
            "client_id": clientId, "client_secret": clientSecret, "code": code,
            "code_verifier": verifier, "redirect_uri": redirect, "grant_type": "authorization_code",
        ])) as? [String: Any] ?? [:]
        guard let refresh = json.str("refresh_token") else {
            throw SideStatsError("Google did not return a refresh token")
        }
        Secret.googleClientSecret.set(clientSecret)
        Secret.googleRefreshToken.set(refresh)
        accessToken = json.str("access_token")
        expiresAt = Date().addingTimeInterval(json.num("expires_in"))
    }
}

/// One-shot HTTP listener on 127.0.0.1 that captures the OAuth redirect query.
final class LoopbackReceiver: @unchecked Sendable {
    private let listener: NWListener
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var pending: Result<[String: String], Error>?
    private let queue = DispatchQueue(label: "sidestats.oauth")

    init() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            var resumed = false
            listener.stateUpdateHandler = { [weak self] state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    cont.resume(returning: self?.listener.port?.rawValue ?? 0)
                case .failed(let e):
                    resumed = true
                    cont.resume(throwing: e)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            listener.start(queue: queue)
        }
    }

    func waitForCallback(timeout: TimeInterval) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                if let p = self.pending { self.pending = nil; cont.resume(with: p); return }
                self.continuation = cont
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    self.finish(.failure(SideStatsError("Timed out waiting for Google sign-in")))
                }
            }
        }
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let path = text.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let items = URLComponents(string: "http://x\(path)")?.queryItems ?? []
            var params: [String: String] = [:]
            for i in items { params[i.name] = i.value ?? "" }
            if params.isEmpty {   // favicon or unrelated request
                conn.send(content: Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n".utf8),
                          completion: .contentProcessed { _ in conn.cancel() })
                return
            }
            let html = "<html><body style='font:16px -apple-system;text-align:center;padding:60px'>"
                + "<h2>SideStats is connected</h2><p>You can close this tab.</p></body></html>"
            let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
            conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in conn.cancel() })
            self?.finish(.success(params))
        }
    }

    private func finish(_ result: Result<[String: String], Error>) {
        guard let c = continuation else {
            if pending == nil { pending = result }
            listener.cancel()
            return
        }
        continuation = nil
        listener.cancel()
        c.resume(with: result)
    }
}
