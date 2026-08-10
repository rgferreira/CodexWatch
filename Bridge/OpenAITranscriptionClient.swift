import Foundation

actor OpenAITranscriptionClient {
    enum TranscriptionError: LocalizedError {
        case missingAPIKey
        case invalidResponse
        case rejected(String)
        case emptyTranscript

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                "Configura una API key de OpenAI en Codex Watch Bridge."
            case .invalidResponse:
                "OpenAI devolvió una respuesta de transcripción no válida."
            case .rejected(let message):
                "OpenAI rechazó la transcripción: \(message)"
            case .emptyTranscript:
                "OpenAI no detectó ninguna orden en la nota de voz."
            }
        }
    }

    private struct APIResponse: Decodable {
        struct Segment: Decodable { let text: String }
        let text: String?
        let segments: [Segment]?
    }

    private struct APIErrorResponse: Decodable {
        struct APIError: Decodable { let message: String }
        let error: APIError
    }

    func transcribe(
        audioURL: URL,
        model: OpenAITranscriptionModel,
        apiKey: String
    ) async throws -> String {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw TranscriptionError.missingAPIKey }

        let audio = try Data(contentsOf: audioURL, options: [.mappedIfSafe])
        let boundary = "CodexWatch-\(UUID().uuidString)"
        var body = Data()
        body.appendFormField(name: "model", value: model.rawValue, boundary: boundary)
        if model == .gptTranscribe {
            body.appendFormField(name: "languages[]", value: "es", boundary: boundary)
        } else {
            body.appendFormField(name: "language", value: "es", boundary: boundary)
        }
        if model.usesDiarizedResponse {
            body.appendFormField(name: "response_format", value: "diarized_json", boundary: boundary)
            body.appendFormField(name: "chunking_strategy", value: "auto", boundary: boundary)
        } else {
            body.appendFormField(name: "response_format", value: "json", boundary: boundary)
        }
        body.appendFile(
            name: "file",
            filename: "watch-order.m4a",
            mimeType: "audio/mp4",
            data: audio,
            boundary: boundary
        )
        body.append(Data("--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 75
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(APIErrorResponse.self, from: data))?.error.message
                ?? "código HTTP \(http.statusCode)"
            throw TranscriptionError.rejected(message)
        }

        let decoded = try JSONDecoder().decode(APIResponse.self, from: data)
        let transcript = decoded.text
            ?? decoded.segments?.map(\.text).joined(separator: " ")
            ?? ""
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TranscriptionError.emptyTranscript }
        return trimmed
    }
}

private extension Data {
    mutating func appendFormField(name: String, value: String, boundary: String) {
        append(Data("--\(boundary)\r\n".utf8))
        append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        append(Data("\(value)\r\n".utf8))
    }

    mutating func appendFile(
        name: String,
        filename: String,
        mimeType: String,
        data: Data,
        boundary: String
    ) {
        append(Data("--\(boundary)\r\n".utf8))
        append(Data("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".utf8))
        append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        append(data)
        append(Data("\r\n".utf8))
    }
}
