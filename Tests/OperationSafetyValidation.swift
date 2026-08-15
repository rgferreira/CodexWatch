import Foundation

@main
struct OperationSafetyValidation {
    static func main() {
        let now = Date(timeIntervalSince1970: 1_000)
        let first = UUID()
        let second = UUID()
        var safety = BridgeOperationSafety()

        precondition(safety.beginWrite(commandID: first, threadID: "thread-a", now: now) == .started)
        precondition(safety.beginWrite(commandID: first, threadID: "thread-a", now: now) == .duplicate(
            CommandReceipt(commandID: first, state: .queued, message: "Operación en curso")
        ))
        precondition(safety.beginWrite(commandID: second, threadID: "thread-a", now: now) == .threadBusy)
        precondition(safety.beginWrite(commandID: second, threadID: "thread-b", now: now) == .started)

        let sent = CommandReceipt(commandID: first, state: .sent, message: "sent")
        safety.finishWrite(threadID: "thread-a", receipt: sent, now: now)
        precondition(safety.beginWrite(commandID: first, threadID: "thread-a", now: now) == .duplicate(sent))

        var breaker = OperationCircuitBreaker(failureThreshold: 3, cooldown: 60)
        breaker.recordFailure(at: now)
        breaker.recordFailure(at: now)
        precondition(breaker.allowsOperation(at: now))
        breaker.recordFailure(at: now)
        precondition(!breaker.allowsOperation(at: now.addingTimeInterval(59)))
        precondition(breaker.allowsOperation(at: now.addingTimeInterval(60)))

        // Three bounded failures (slow server, dropped network, terminated
        // process) open the per-thread circuit and stop a fourth device from
        // hammering the same task until cooldown expires.
        var protectedThread = BridgeOperationSafety()
        for offset in 0..<3 {
            let commandID = UUID()
            precondition(protectedThread.beginWrite(
                commandID: commandID,
                threadID: "already-active-thread",
                now: now.addingTimeInterval(Double(offset))
            ) == .started)
            protectedThread.finishWrite(
                threadID: "already-active-thread",
                receipt: CommandReceipt(commandID: commandID, state: .failed, message: "simulated failure"),
                now: now.addingTimeInterval(Double(offset))
            )
        }
        precondition(protectedThread.beginWrite(
            commandID: UUID(),
            threadID: "already-active-thread",
            now: now.addingTimeInterval(3)
        ) == .circuitOpen)

        print("Operation safety validation passed")
    }
}
