import Foundation
import Security

public struct Credentials: Codable, Equatable, Sendable {
    public var deviceId: String
    public var authToken: String
    public init(deviceId: String, authToken: String) {
        self.deviceId = deviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        self.authToken = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum KeychainError: Error, LocalizedError {
    case status(OSStatus)
    public var errorDescription: String? {
        if case .status(let s) = self {
            let msg = SecCopyErrorMessageString(s, nil) as String? ?? "unknown"
            return "Keychain error \(s): \(msg)"
        }
        return nil
    }
}

/// The per-device credential pair lives in the login keychain as one generic
/// password item. `GP_KEYCHAIN_SERVICE` isolates test instances.
public enum CredentialStore {
    static var service: String {
        ProcessInfo.processInfo.environment["GP_KEYCHAIN_SERVICE"] ?? "com.gameprint.companion"
    }
    static let account = "device-credentials"

    public static func save(_ creds: Credentials) throws {
        let data = try JSONEncoder().encode(creds)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add.merge(update) { $1 }
            add[kSecAttrLabel as String] = "GamePrint Companion device credential"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    public static func load() -> Credentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else {
            if status != errSecItemNotFound { logWarn("Keychain read failed with status \(status)") }
            return nil
        }
        return try? JSONDecoder().decode(Credentials.self, from: data)
    }

    public static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
