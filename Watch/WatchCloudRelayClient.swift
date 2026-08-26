import CryptoKit
import Foundation

actor WatchCloudRelayClient {
    private let transport: BlindMailboxHTTPClient
    private let pairingID: String
    private let key: SymmetricKey

    init(
        configuration: CloudRelayTransportConfiguration,
        pairing: CloudRelayProtocol.PairingMaterial
    ) throws {
        guard let peerPublicKey = pairing.peerPublicKey,
              pairing.pairingID == configuration.pairingID,
              pairing.isApproved else {
            throw BlindMailboxHTTPClient.ClientError.invalidConfiguration
        }
        transport = BlindMailboxHTTPClient(configuration: try .init(
            baseURL: configuration.baseURL,
            pairingID: configuration.pairingID,
            transportSecret: configuration.transportSecret
        ))
        pairingID = configuration.pairingID
        key = try CloudRelayProtocol.sharedKey(
            privateKey: pairing.privateKey,
            peerPublicKey: peerPublicKey,
            pairingID: configuration.pairingID
        )
    }

    func send(_ command: CodexCommand) async throws {
        let payload = try CloudRelayProtocol.SealedPayload(
            commandID: command.id,
            operation: .textCommand,
            body: command
        )
        try await transport.put(CloudRelayProtocol.seal(
            payload: payload,
            pairingID: pairingID,
            direction: .watchToMac,
            key: key
        ))
    }

    func sendHeartbeat() async throws {
        let identifier = UUID()
        let payload = try CloudRelayProtocol.SealedPayload(
            commandID: identifier,
            operation: .heartbeat,
            body: CloudRelayProtocol.Heartbeat(sentAt: Date())
        )
        try await transport.put(CloudRelayProtocol.seal(
            payload: payload,
            pairingID: pairingID,
            direction: .watchToMac,
            key: key
        ))
    }

    func receiveOnce(waitSeconds: Int = 20) async throws -> [CommandReceipt] {
        let claims = try await transport.claim(
            direction: .macToWatch,
            waitSeconds: waitSeconds,
            leaseSeconds: 45,
            limit: 4
        )
        var receipts: [CommandReceipt] = []
        for claim in claims {
            let payload = try CloudRelayProtocol.open(
                claim.envelope,
                expectedDirection: .macToWatch,
                key: key
            )
            guard payload.operation == .commandReceipt else { continue }
            let receipt = try payload.decode(CommandReceipt.self)
            guard receipt.commandID == payload.commandID else {
                throw CloudRelayProtocol.ProtocolError.recordBindingMismatch
            }
            try await transport.acknowledge(
                recordID: claim.recordID,
                leaseToken: claim.leaseToken
            )
            receipts.append(receipt)
        }
        return receipts
    }
}
