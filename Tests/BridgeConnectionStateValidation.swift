import Foundation

@main
struct BridgeConnectionStateValidation {
    static func main() {
        let now = Date(timeIntervalSince1970: 10_000)
        let timeout: TimeInterval = 45

        expect(
            .unavailable,
            localServicesReady: false,
            contact: now,
            now: now,
            timeout: timeout
        )
        expect(
            .waitingForCompanion,
            localServicesReady: true,
            contact: nil,
            now: now,
            timeout: timeout
        )
        expect(
            .connected,
            localServicesReady: true,
            contact: now.addingTimeInterval(-15),
            now: now,
            timeout: timeout
        )
        expect(
            .connected,
            localServicesReady: true,
            contact: now.addingTimeInterval(-timeout),
            now: now,
            timeout: timeout
        )
        expect(
            .waitingForCompanion,
            localServicesReady: true,
            contact: now.addingTimeInterval(-timeout - 0.001),
            now: now,
            timeout: timeout
        )

        print("BridgeConnectionState validation passed")
    }

    private static func expect(
        _ expected: BridgeConnectionState,
        localServicesReady: Bool,
        contact: Date?,
        now: Date,
        timeout: TimeInterval
    ) {
        let actual = BridgeConnectionState.resolve(
            localServicesReady: localServicesReady,
            lastSuccessfulCompanionContact: contact,
            now: now,
            contactTimeout: timeout
        )
        precondition(actual == expected, "Expected \(expected), got \(actual)")
    }
}
