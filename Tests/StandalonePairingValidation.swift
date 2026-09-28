import Foundation

@main
struct StandalonePairingValidation {
    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let macPrivate = CloudRelayProtocol.generatePrivateKey()
        let watchPrivate = CloudRelayProtocol.generatePrivateKey()
        let macPublic = try CloudRelayProtocol.publicKey(for: macPrivate)
        let watchPublic = try CloudRelayProtocol.publicKey(for: watchPrivate)
        let configuration = CloudRelayTransportConfiguration(
            baseURL: URL(string: "https://mailbox.example.invalid/v1")!,
            pairingID: "standalone-validation",
            transportSecret: Data(repeating: 0x2a, count: 32)
        )
        let offer = CloudRelayStandaloneBootstrapOffer(
            bootstrapID: UUID(uuidString: "EF168C40-047B-48DB-A214-A1064863C98C")!,
            createdAt: now,
            configuration: configuration,
            macDeviceID: "validation-mac",
            macPublicKey: macPublic
        )
        precondition(offer.isValid(at: now))
        precondition(offer.isValid(at: offer.expiresAt))
        precondition(!offer.isValid(at: offer.expiresAt.addingTimeInterval(1)))

        let proposal = CloudRelayStandaloneBootstrapResponse(
            offer: offer,
            watchDeviceID: "validation-watch",
            watchPublicKey: watchPublic,
            approvedOnWatch: false,
            updatedAt: now
        )
        precondition(proposal.matches(offer, at: now))
        precondition(!proposal.approvedOnWatch)
        precondition(proposal.authenticationCode.count == 6)

        let approval = CloudRelayStandaloneBootstrapResponse(
            offer: offer,
            watchDeviceID: proposal.watchDeviceID,
            watchPublicKey: proposal.watchPublicKey,
            approvedOnWatch: true,
            updatedAt: now.addingTimeInterval(1)
        )
        precondition(approval.matches(offer, at: now.addingTimeInterval(1)))
        precondition(approval.approvedOnWatch)
        precondition(approval.authenticationCode == proposal.authenticationCode)

        let foreignOffer = CloudRelayStandaloneBootstrapOffer(
            createdAt: now,
            configuration: configuration,
            macDeviceID: offer.macDeviceID,
            macPublicKey: offer.macPublicKey
        )
        precondition(!approval.matches(foreignOffer, at: now))

        let alteredConfigurationOffer = CloudRelayStandaloneBootstrapOffer(
            bootstrapID: offer.bootstrapID,
            createdAt: offer.createdAt,
            configuration: .init(
                baseURL: URL(string: "https://altered.example.invalid/v1")!,
                pairingID: configuration.pairingID,
                transportSecret: configuration.transportSecret
            ),
            macDeviceID: offer.macDeviceID,
            macPublicKey: offer.macPublicKey
        )
        precondition(!approval.matches(alteredConfigurationOffer, at: now))
        precondition(
            approval.authenticationCode
                != CloudRelayProtocol.shortAuthenticationString(
                    pairingID: alteredConfigurationOffer.configuration.pairingID,
                    firstPublicKey: approval.watchPublicKey,
                    secondPublicKey: alteredConfigurationOffer.macPublicKey,
                    binding: alteredConfigurationOffer.bindingDigest()
                )
        )

        let insecureOffer = CloudRelayStandaloneBootstrapOffer(
            createdAt: now,
            configuration: .init(
                baseURL: URL(string: "http://mailbox.example.invalid/v1")!,
                pairingID: configuration.pairingID,
                transportSecret: configuration.transportSecret
            ),
            macDeviceID: offer.macDeviceID,
            macPublicKey: offer.macPublicKey
        )
        precondition(!insecureOffer.isValid(at: now))

        let encodedOffer = try JSONEncoder().encode(offer)
        let decodedOffer = try JSONDecoder().decode(
            CloudRelayStandaloneBootstrapOffer.self,
            from: encodedOffer
        )
        precondition(decodedOffer == offer)
        let encodedApproval = try JSONEncoder().encode(approval)
        let decodedApproval = try JSONDecoder().decode(
            CloudRelayStandaloneBootstrapResponse.self,
            from: encodedApproval
        )
        precondition(decodedApproval == approval)

        let macKey = try CloudRelayProtocol.sharedKey(
            privateKey: macPrivate,
            peerPublicKey: watchPublic,
            pairingID: configuration.pairingID
        )
        let watchKey = try CloudRelayProtocol.sharedKey(
            privateKey: watchPrivate,
            peerPublicKey: macPublic,
            pairingID: configuration.pairingID
        )
        precondition(macKey == watchKey)

        let normalizedVoiceConfiguration = VoiceConfiguration.updated(
            inputMode: .openAIAPI,
            transcriptionModel: .gptTranscribe,
            at: Date(timeIntervalSince1970: 1_800_000_000.875)
        )
        precondition(
            normalizedVoiceConfiguration.updatedAt.timeIntervalSince1970
                == 1_800_000_000
        )

        print("Standalone Watch-Mac pairing validation passed")
    }
}
