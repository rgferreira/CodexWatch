import Foundation

struct AuthenticationRateLimiter {
    enum Decision: Equatable {
        case authorized
        case unauthorized
        case rateLimited
    }

    private struct FailureState {
        var attempts: [Date] = []
        var blockedUntil: Date?
    }

    private var failures: [String: FailureState] = [:]

    mutating func evaluate(
        clientIdentifier: String,
        suppliedToken: String,
        expectedToken: String,
        now: Date = Date()
    ) -> Decision {
        failures = failures.filter { _, state in
            state.blockedUntil.map { $0 > now } ?? state.attempts.contains { now.timeIntervalSince($0) < 600 }
        }

        var state = failures[clientIdentifier] ?? FailureState()
        if let blockedUntil = state.blockedUntil, blockedUntil > now { return .rateLimited }

        if Self.constantTimeEquals(suppliedToken, expectedToken) {
            failures.removeValue(forKey: clientIdentifier)
            return .authorized
        }

        state.attempts = state.attempts.filter { now.timeIntervalSince($0) < 60 }
        state.attempts.append(now)
        if state.attempts.count >= 5 {
            state.blockedUntil = now.addingTimeInterval(5 * 60)
        }
        if failures.count < 128 || failures[clientIdentifier] != nil {
            failures[clientIdentifier] = state
        }
        return state.blockedUntil == nil ? .unauthorized : .rateLimited
    }

    mutating func reset() {
        failures.removeAll()
    }

    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        let count = max(left.count, right.count)
        var difference = left.count ^ right.count
        for index in 0..<count {
            let leftByte = index < left.count ? left[index] : 0
            let rightByte = index < right.count ? right[index] : 0
            difference |= Int(leftByte ^ rightByte)
        }
        return difference == 0
    }
}
