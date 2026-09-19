import Foundation
import LocalAuthentication
import Security

enum SecureTokenStore {
    #if os(watchOS)
    private static let standaloneBundleID = "com.rgferreira.CodexWatchStandalone"
    private static let legacyWatchAccessGroup =
        "RR6C5FHDDS.com.rgferreira.CodexWatchCompanion.watchapp"

    private static var shouldReadLegacyWatchKeychain: Bool {
        Bundle.main.bundleIdentifier == standaloneBundleID
    }
    #endif

    enum StoreError: LocalizedError {
        case keychain(OSStatus)
        case invalidStoredValue
        case randomGeneration(OSStatus)

        var errorDescription: String? {
            switch self {
            case .keychain(let status):
                return "El llavero devolvió el error \(status)."
            case .invalidStoredValue:
                return "El token guardado no es válido."
            case .randomGeneration(let status):
                return "No se pudo generar un token seguro (\(status))."
            }
        }
    }

    static func load(service: String, account: String) throws -> String? {
        guard let data = try loadData(service: service, account: account) else { return nil }
        guard let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            throw StoreError.invalidStoredValue
        }
        return value
    }

    static func loadData(service: String, account: String) throws -> Data? {
        if let value = try loadData(service: service, account: account, accessGroup: nil) {
            return value
        }
        #if os(watchOS)
        if shouldReadLegacyWatchKeychain {
            return try loadData(
                service: service,
                account: account,
                accessGroup: legacyWatchAccessGroup
            )
        }
        #endif
        return nil
    }

    private static func loadData(
        service: String,
        account: String,
        accessGroup: String?
    ) throws -> Data? {
        let authenticationContext = LAContext()
        authenticationContext.interactionNotAllowed = true
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnData: true,
            kSecUseAuthenticationContext: authenticationContext
        ]
        if let accessGroup { query[kSecAttrAccessGroup] = accessGroup }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
        guard let data = result as? Data, !data.isEmpty else {
            throw StoreError.invalidStoredValue
        }
        return data
    }

    static func save(_ value: String, service: String, account: String) throws {
        try saveData(Data(value.utf8), service: service, account: account)
    }

    static func saveData(_ value: Data, service: String, account: String) throws {
        guard !value.isEmpty else { throw StoreError.invalidStoredValue }
        let identity: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: value,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = identity
            attributes.forEach { item[$0.key] = $0.value }
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw StoreError.keychain(addStatus) }
        } else if status != errSecSuccess {
            throw StoreError.keychain(status)
        }
    }

    static func delete(service: String, account: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError.keychain(status)
        }
    }

    static func accounts(service: String) throws -> [String] {
        var values = try accounts(service: service, accessGroup: nil)
        #if os(watchOS)
        if shouldReadLegacyWatchKeychain {
            values.append(contentsOf: try accounts(
                service: service,
                accessGroup: legacyWatchAccessGroup
            ))
        }
        #endif
        return Array(Set(values)).sorted()
    }

    private static func accounts(service: String, accessGroup: String?) throws -> [String] {
        let authenticationContext = LAContext()
        authenticationContext.interactionNotAllowed = true
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecMatchLimit: kSecMatchLimitAll,
            kSecReturnAttributes: true,
            kSecUseAuthenticationContext: authenticationContext
        ]
        if let accessGroup { query[kSecAttrAccessGroup] = accessGroup }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
        let rows: [[String: Any]]
        if let values = result as? [[String: Any]] {
            rows = values
        } else if let value = result as? [String: Any] {
            rows = [value]
        } else {
            throw StoreError.invalidStoredValue
        }
        return rows.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    static func loadOrCreate(service: String, account: String) throws -> String {
        if let existing = try load(service: service, account: account) { return existing }
        let token = try makeToken()
        try save(token, service: service, account: account)
        return token
    }

    static func makeToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw StoreError.randomGeneration(status) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
