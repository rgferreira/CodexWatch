import Foundation

struct CloudRelayTransportConfiguration: Codable, Hashable, Sendable {
    let baseURL: URL
    let pairingID: String
    let transportSecret: Data
}

struct CloudRelayPairingRequest: Codable, Hashable, Sendable {
    let watchDeviceID: String
    let watchPublicKey: Data
}

struct CloudRelayPairingOffer: Codable, Hashable, Sendable {
    let configuration: CloudRelayTransportConfiguration
    let macDeviceID: String
    let macPublicKey: Data
    let watchDeviceID: String
    let watchPublicKey: Data
    let authenticationCode: String
}

struct CloudRelayPairingApproval: Codable, Hashable, Sendable {
    let pairingID: String
    let watchDeviceID: String
    let watchPublicKey: Data
    let authenticationCode: String
}

struct CloudRelayPairingResult: Codable, Hashable, Sendable {
    let pairingID: String
    let accepted: Bool
    let message: String
}

