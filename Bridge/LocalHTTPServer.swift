import Foundation
import Network

struct HTTPRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
    let clientIdentifier: String
}

struct HTTPResponse: Sendable {
    let status: Int
    let reason: String
    let contentType: String
    let body: Data

    static let badRequest = text(status: 400, reason: "Bad Request", value: "Solicitud no válida")
    static let unauthorized = text(status: 401, reason: "Unauthorized", value: "No autorizado")
    static let notFound = text(status: 404, reason: "Not Found", value: "Ruta no encontrada")
    static let payloadTooLarge = text(status: 413, reason: "Payload Too Large", value: "Solicitud demasiado grande")
    static let rateLimited = text(status: 429, reason: "Too Many Requests", value: "Demasiados intentos")

    static func serverError() -> HTTPResponse {
        text(status: 500, reason: "Internal Server Error", value: "No se pudo completar la operación")
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
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        var result = Data(head.utf8)
        result.append(body)
        return result
    }
}

final class LocalHTTPServer: @unchecked Sendable {
    private enum ParseResult {
        case incomplete
        case request(HTTPRequest)
        case failure(HTTPResponse)
    }

    private static let maximumHeaderBytes = 16 * 1024
    private static let maximumBodyBytes = 64 * 1024
    private static let maximumRequestBytes = maximumHeaderBytes + maximumBodyBytes + 4
    private static let maximumConnections = 24

    private let listener: NWListener
    private let queue = DispatchQueue(label: "CodexWatch.HTTPServer")
    private let handler: @Sendable (HTTPRequest) async -> HTTPResponse
    private var connections: [UUID: NWConnection] = [:]

    init(
        bindAddress: String,
        port: UInt16,
        onStateChange: @escaping @Sendable (Bool, String?) -> Void = { _, _ in },
        handler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse
    ) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw URLError(.badURL) }
        self.handler = handler

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(bindAddress), port: nwPort)
        listener = try NWListener(using: parameters)
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

    deinit {
        listener.cancel()
        connections.values.forEach { $0.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < Self.maximumConnections else {
            connection.cancel()
            return
        }
        let identifier = UUID()
        connections[identifier] = connection
        connection.start(queue: queue)
        receive(on: connection, identifier: identifier, accumulated: Data())
        queue.asyncAfter(deadline: .now() + 30) { [weak self] in
            self?.finish(identifier)
        }
    }

    private func receive(on connection: NWConnection, identifier: UUID, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = accumulated
            if let data { buffer.append(data) }

            switch Self.parse(buffer, clientIdentifier: Self.clientIdentifier(for: connection)) {
            case .request(let request):
                Task {
                    let response = await self.handler(request)
                    self.send(response, on: connection, identifier: identifier)
                }
            case .failure(let response):
                self.send(response, on: connection, identifier: identifier)
            case .incomplete where isComplete || error != nil:
                self.finish(identifier)
            case .incomplete:
                self.receive(on: connection, identifier: identifier, accumulated: buffer)
            }
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection, identifier: UUID) {
        connection.send(content: response.wireData, completion: .contentProcessed { [weak self] _ in
            self?.finish(identifier)
        })
    }

    private func finish(_ identifier: UUID) {
        connections.removeValue(forKey: identifier)?.cancel()
    }

    private static func clientIdentifier(for connection: NWConnection) -> String {
        if case .hostPort(let host, _) = connection.endpoint {
            return String(describing: host)
        }
        return "unknown"
    }

    private static func parse(_ data: Data, clientIdentifier: String) -> ParseResult {
        guard data.count <= maximumRequestBytes else { return .failure(.payloadTooLarge) }

        let delimiter = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: delimiter) else {
            return data.count >= maximumHeaderBytes ? .failure(.payloadTooLarge) : .incomplete
        }
        guard data.distance(from: data.startIndex, to: headerRange.lowerBound) <= maximumHeaderBytes,
              let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else {
            return .failure(.badRequest)
        }

        let lines = headerText.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ", omittingEmptySubsequences: true).map(String.init) ?? []
        guard requestLine.count == 3,
              requestLine[2] == "HTTP/1.1" || requestLine[2] == "HTTP/1.0",
              requestLine[1].hasPrefix("/"),
              requestLine[1].utf8.count <= 2_048 else {
            return .failure(.badRequest)
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { return .failure(.badRequest) }
            let name = String(line[..<separator]).lowercased()
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, headers[name] == nil else { return .failure(.badRequest) }
            headers[name] = value
        }
        guard headers["transfer-encoding"] == nil else { return .failure(.badRequest) }

        let expectedLength: Int
        if let rawLength = headers["content-length"] {
            guard let parsedLength = Int(rawLength), parsedLength >= 0 else { return .failure(.badRequest) }
            guard parsedLength <= maximumBodyBytes else { return .failure(.payloadTooLarge) }
            expectedLength = parsedLength
        } else {
            expectedLength = 0
        }

        let bodyStart = headerRange.upperBound
        guard let bodyEnd = data.index(bodyStart, offsetBy: expectedLength, limitedBy: data.endIndex) else {
            return .incomplete
        }
        guard data.distance(from: bodyStart, to: data.endIndex) >= expectedLength else { return .incomplete }
        let body = data.subdata(in: bodyStart..<bodyEnd)
        return .request(HTTPRequest(
            method: requestLine[0],
            path: requestLine[1],
            headers: headers,
            body: body,
            clientIdentifier: clientIdentifier
        ))
    }
}
