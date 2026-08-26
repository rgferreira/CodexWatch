import CryptoKit
import Foundation

private struct ProvisionedTransport: Decodable {
    let baseURL: URL
    let pairingID: String
    let transportSecret: Data

    private enum CodingKeys: String, CodingKey {
        case baseURL = "base_url"
        case pairingID = "pairing_id"
        case transportSecret = "transport_secret_base64"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try values.decode(URL.self, forKey: .baseURL)
        pairingID = try values.decode(String.self, forKey: .pairingID)
        let encoded = try values.decode(String.self, forKey: .transportSecret)
        guard let data = Data(base64Encoded: encoded), data.count >= 32 else {
            throw DecodingError.dataCorruptedError(
                forKey: .transportSecret,
                in: values,
                debugDescription: "Invalid transport secret"
            )
        }
        transportSecret = data
    }
}

@main
struct LiveMailboxTransportProbe {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            throw NSError(domain: "LiveMailboxProbe", code: 1)
        }
        let materialURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let material = try CodexWatchWire.decode(
            ProvisionedTransport.self,
            from: Data(contentsOf: materialURL)
        )
        let configuration = try BlindMailboxHTTPClient.Configuration(
            baseURL: material.baseURL,
            pairingID: material.pairingID,
            transportSecret: material.transportSecret
        )
        let client = BlindMailboxHTTPClient(configuration: configuration)
        let watchPrivateKey = CloudRelayProtocol.generatePrivateKey()
        let macPrivateKey = CloudRelayProtocol.generatePrivateKey()
        let sharedKey = try CloudRelayProtocol.sharedKey(
            privateKey: watchPrivateKey,
            peerPublicKey: CloudRelayProtocol.publicKey(for: macPrivateKey),
            pairingID: material.pairingID
        )
        let commandID = UUID()
        let payload = try CloudRelayProtocol.SealedPayload(
            commandID: commandID,
            operation: .heartbeat,
            body: CloudRelayProtocol.Heartbeat(sentAt: Date())
        )
        let envelope = try CloudRelayProtocol.seal(
            payload: payload,
            pairingID: material.pairingID,
            direction: .watchToMac,
            key: sharedKey
        )
        try await client.put(envelope)
        let claims = try await client.claim(
            direction: .watchToMac,
            waitSeconds: 0,
            leaseSeconds: 30,
            limit: 1
        )
        guard let claim = claims.first,
              claim.recordID == envelope.context.recordName else {
            throw NSError(domain: "LiveMailboxProbe", code: 2)
        }
        let opened = try CloudRelayProtocol.open(
            claim.envelope,
            expectedDirection: .watchToMac,
            key: sharedKey
        )
        guard opened.commandID == commandID, opened.operation == .heartbeat else {
            throw NSError(domain: "LiveMailboxProbe", code: 3)
        }
        try await client.acknowledge(
            recordID: claim.recordID,
            leaseToken: claim.leaseToken
        )
        print("Live encrypted mailbox round trip passed")
    }
}
