import Foundation
import Darwin

enum ZeroTierAddressDetector {
    struct IPv4Network {
        let address: String
        let prefixLength: Int
    }

    enum DetectionError: LocalizedError {
        case commandUnavailable
        case noActiveIPv4Address

        var errorDescription: String? {
            switch self {
            case .commandUnavailable:
                return "No se encuentra ZeroTier en este Mac."
            case .noActiveIPv4Address:
                return "ZeroTier no tiene una red activa con dirección IPv4."
            }
        }
    }

    private struct Network: Decodable {
        let status: String?
        let portDeviceName: String?
        let assignedAddresses: [String]?
    }

    static func activeIPv4Network() throws -> IPv4Network {
        let candidates = [
            "/usr/local/bin/zerotier-cli",
            "/opt/homebrew/bin/zerotier-cli",
            "/Library/Application Support/ZeroTier/One/zerotier-cli",
            "/Applications/ZeroTier One.app/Contents/MacOS/zerotier-cli"
        ]

        var foundExecutable = false
        for executable in candidates where FileManager.default.isExecutableFile(atPath: executable) {
            foundExecutable = true
            guard let output = run(executable) else { continue }
            guard let networks = try? JSONDecoder().decode([Network].self, from: output) else { continue }
            for network in networks where network.status == "OK" {
                guard network.portDeviceName?.isEmpty == false else { continue }
                for assignment in network.assignedAddresses ?? [] {
                    let components = assignment.split(separator: "/", maxSplits: 1).map(String.init)
                    guard components.count == 2,
                          let prefixLength = Int(components[1]),
                          (0...32).contains(prefixLength),
                          isValidIPv4(components[0]) else { continue }
                    return IPv4Network(address: components[0], prefixLength: prefixLength)
                }
            }
        }

        if !foundExecutable { throw DetectionError.commandUnavailable }
        throw DetectionError.noActiveIPv4Address
    }

    private static func run(_ executable: String) -> Data? {
        let process = Process()
        let standardOutput = Pipe()
        let finished = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-j", "listnetworks"]
        process.standardOutput = standardOutput
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
            guard finished.wait(timeout: .now() + 3) == .success else {
                process.terminate()
                return nil
            }
            guard process.terminationStatus == 0 else { return nil }
            return standardOutput.fileHandleForReading.readDataToEndOfFile()
        } catch {
            return nil
        }
    }

    private static func isValidIPv4(_ value: String) -> Bool {
        var address = in_addr()
        return value.withCString { inet_pton(AF_INET, $0, &address) == 1 }
    }
}
