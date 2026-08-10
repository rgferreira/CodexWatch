import Foundation
import Network

struct HTTPRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

struct HTTPResponse: Sendable {
    let status: Int
    let reason: String
    let contentType: String
    let body: Data

    static let unauthorized = text(status: 401, reason: "Unauthorized", value: "Código incorrecto")
    static let notFound = text(status: 404, reason: "Not Found", value: "Ruta no encontrada")

    static func serverError(_ value: String) -> HTTPResponse {
        text(status: 500, reason: "Internal Server Error", value: value)
    }

    static func json(_ value: [String: String]) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: value)) ?? Data("{}".utf8)
        return HTTPResponse(status: 200, reason: "OK", contentType: "application/json", body: data)
    }

    static func encodable<T: Encodable>(_ value: T) -> HTTPResponse {
        let data = (try? CodexWatchWire.encode(value)) ?? Data("{}".utf8)
        return HTTPResponse(status: 200, reason: "OK", contentType: "application/json", body: data)
    }

    private static func text(status: Int, reason: String, value: String) -> HTTPResponse {
        HTTPResponse(status: status, reason: reason, contentType: "text/plain; charset=utf-8", body: Data(value.utf8))
    }

    var wireData: Data {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var result = Data(head.utf8)
        result.append(body)
        return result
    }
}

final class LocalHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "CodexWatch.HTTPServer")
    private let handler: @Sendable (HTTPRequest) async -> HTTPResponse

    init(
        port: UInt16,
        onStateChange: @escaping @Sendable (Bool, String?) -> Void = { _, _ in },
        handler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse
    ) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw URLError(.badURL) }
        self.handler = handler
        listener = try NWListener(using: .tcp, on: nwPort)
        listener.service = NWListener.Service(name: "Codex Watch Bridge", type: "_codexwatch._tcp")
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                onStateChange(true, nil)
            case .failed(let error):
                onStateChange(false, error.localizedDescription)
            case .cancelled:
                onStateChange(false, "Servidor detenido")
            default:
                onStateChange(false, nil)
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
    }

    deinit { listener.cancel() }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, accumulated: Data())
    }

    private func receive(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = accumulated
            if let data { buffer.append(data) }

            if let request = Self.parse(buffer) {
                Task {
                    let response = await self.handler(request)
                    connection.send(content: response.wireData, completion: .contentProcessed { _ in connection.cancel() })
                }
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receive(on: connection, accumulated: buffer)
            }
        }
    }

    private static func parse(_ data: Data) -> HTTPRequest? {
        let delimiter = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: delimiter),
              let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else { return nil }

        let lines = headerText.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ").map(String.init) ?? []
        guard requestLine.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let pieces = line.split(separator: ":", maxSplits: 1).map(String.init)
            if pieces.count == 2 {
                headers[pieces[0].lowercased()] = pieces[1].trimmingCharacters(in: .whitespaces)
            }
        }

        let bodyStart = headerRange.upperBound
        let expected = Int(headers["content-length"] ?? "0") ?? 0
        guard data.count >= bodyStart + expected else { return nil }
        let body = data.subdata(in: bodyStart..<(bodyStart + expected))
        return HTTPRequest(method: requestLine[0], path: requestLine[1], headers: headers, body: body)
    }
}
