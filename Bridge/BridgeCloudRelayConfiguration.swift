import Foundation

struct BridgeCloudRelayProvisioning: Decodable, Sendable {
    let baseURL: URL
    let pairingID: String
    let transportSecret: Data

    private enum CodingKeys: String, CodingKey {
        case baseURL = "base_url"
        case pairingID = "pairing_id"
        case transportSecretBase64 = "transport_secret_base64"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try values.decode(URL.self, forKey: .baseURL)
        pairingID = try values.decode(String.self, forKey: .pairingID)
        let encoded = try values.decode(String.self, forKey: .transportSecretBase64)
        guard let secret = Data(base64Encoded: encoded), secret.count >= 32 else {
            throw DecodingError.dataCorruptedError(
                forKey: .transportSecretBase64,
                in: values,
                debugDescription: "Invalid mailbox transport secret"
            )
        }
        transportSecret = secret
    }

    static func load() throws -> Self {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexWatchBridge", isDirectory: true)
            .appendingPathComponent("cloud-mailbox-transport.json")
        let values = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (values[.posixPermissions] as? NSNumber)?.intValue == 0o600 else {
            throw CocoaError(.fileReadNoPermission)
        }
        return try CodexWatchWire.decode(Self.self, from: Data(contentsOf: url))
    }

    var transportConfiguration: CloudRelayTransportConfiguration {
        .init(baseURL: baseURL, pairingID: pairingID, transportSecret: transportSecret)
    }
}
