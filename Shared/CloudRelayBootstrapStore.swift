import Foundation
import LocalAuthentication
import Security

/// A tiny rendezvous channel backed by the user's end-to-end encrypted iCloud
/// Keychain. It is used only before the normal Watch<->Mac E2E mailbox exists.
/// Records expire in fifteen minutes and contain no Codex credentials.
enum CloudRelayBootstrapStore {
    private static let service = "com.rgferreira.CodexWatch.StandaloneBootstrap.v1"
    private static let accessGroup = "RR6C5FHDDS.com.rgferreira.CodexWatch.bootstrap"
    private static let offerAccount = "active-offer"
    private static let responseAccount = "active-response"

    static func saveOffer(_ offer: CloudRelayStandaloneBootstrapOffer) throws {
        try save(offer, account: offerAccount)
    }

    static func loadOffer() throws -> CloudRelayStandaloneBootstrapOffer? {
        try load(CloudRelayStandaloneBootstrapOffer.self, account: offerAccount)
    }

    static func deleteOffer() throws {
        try delete(account: offerAccount)
    }

    static func saveResponse(_ response: CloudRelayStandaloneBootstrapResponse) throws {
        try save(response, account: responseAccount)
    }

    static func loadResponse() throws -> CloudRelayStandaloneBootstrapResponse? {
        try load(CloudRelayStandaloneBootstrapResponse.self, account: responseAccount)
    }

    static func deleteResponse() throws {
        try delete(account: responseAccount)
    }

    static func clear() {
        try? deleteOffer()
        try? deleteResponse()
    }

    private static func save<T: Encodable>(_ value: T, account: String) throws {
        let data = try CodexWatchWire.encode(value)
        let match = baseQuery(account: account)
        let update: [CFString: Any] = [kSecValueData: data]
        let status = SecItemUpdate(match as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        if status != errSecItemNotFound { throw SecureTokenStore.StoreError.keychain(status) }

        var item = match
        item[kSecValueData] = data
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw SecureTokenStore.StoreError.keychain(addStatus)
        }
    }

    private static func load<T: Decodable>(
        _ type: T.Type,
        account: String
    ) throws -> T? {
        let context = LAContext()
        context.interactionNotAllowed = true
        var query = baseQuery(account: account)
        query[kSecMatchLimit] = kSecMatchLimitOne
        query[kSecReturnData] = true
        query[kSecUseAuthenticationContext] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw SecureTokenStore.StoreError.keychain(status)
        }
        return try CodexWatchWire.decode(type, from: data)
    }

    private static func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecureTokenStore.StoreError.keychain(status)
        }
    }

    private static func baseQuery(account: String) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrAccessGroup: accessGroup,
            kSecAttrSynchronizable: true
        ]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain] = true
        #endif
        return query
    }
}
