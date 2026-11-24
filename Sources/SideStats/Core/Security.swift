import CryptoKit
import Foundation
import Security

/// Minimal generic-password Keychain wrapper. All provider secrets live here.
enum Keychain {
    private static let service = "app.sidestats.credentials"

    static func get(_ account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ account: String, _ value: String?) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}

enum JWT {
    /// ES256 JWT signed with a P-256 private key in PEM (PKCS#8 or SEC1).
    static func es256(header: [String: Any], payload: [String: Any], pem: String) throws -> String {
        let key = try loadKey(pem)
        let h = try base64url(JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]))
        let p = try base64url(JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
        let input = "\(h).\(p)"
        let sig = try key.signature(for: Data(input.utf8))
        return "\(input).\(base64url(sig.rawRepresentation))"
    }

    static func loadKey(_ pem: String) throws -> P256.Signing.PrivateKey {
        let trimmed = pem.trimmingCharacters(in: .whitespacesAndNewlines)
        if let k = try? P256.Signing.PrivateKey(pemRepresentation: trimmed) { return k }
        // Fall back to raw base64 body (some people paste without the BEGIN/END lines).
        let body = trimmed.components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") }.joined()
        if let der = Data(base64Encoded: body), let k = try? P256.Signing.PrivateKey(derRepresentation: der) {
            return k
        }
        throw SideStatsError("Could not read the private key. Paste the full .p8 / .pem contents.")
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
