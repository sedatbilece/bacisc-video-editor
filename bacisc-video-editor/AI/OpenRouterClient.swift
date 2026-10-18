import Foundation

/// Minimal OpenRouter API client: model list, key check and speech-to-text.
struct OpenRouterClient {
    static let baseURL = URL(string: "https://openrouter.ai/api/v1")!

    struct Model: Decodable, Identifiable, Hashable {
        let id: String
        let name: String
    }

    struct KeyInfo: Decodable {
        let label: String?
        /// Credits used, in USD.
        let usage: Double?
        let limit: Double?
    }

    /// A verbose transcription; times are seconds from the start of the uploaded audio.
    struct Transcription: Decodable {
        struct Segment: Decodable {
            let start: Double
            let end: Double
            let text: String
        }

        struct Word: Decodable {
            let word: String
            let start: Double
            let end: Double
            /// "word", or "spacing" / "audio_event" for some providers.
            let type: String?
        }

        let text: String
        let language: String?
        let segments: [Segment]?
        let words: [Word]?
    }

    enum ClientError: LocalizedError {
        case missingAPIKey
        case http(status: Int, message: String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                "No OpenRouter API key. Add one in Settings > AI > OpenRouter."
            case .http(let status, let message):
                "OpenRouter returned \(status): \(message)"
            }
        }
    }

    let apiKey: String

    /// Uses the key saved in Settings.
    static func configured() throws -> OpenRouterClient {
        guard let key = AISettings.apiKey, !key.isEmpty else { throw ClientError.missingAPIKey }
        return OpenRouterClient(apiKey: key)
    }

    /// Models that take audio and return a transcription. Needs no key.
    static func transcriptionModels() async throws -> [Model] {
        var components = URLComponents(url: baseURL.appending(path: "models"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "output_modalities", value: "transcription")]
        let data = try await send(URLRequest(url: components.url!))
        return try JSONDecoder().decode(DataEnvelope<[Model]>.self, from: data).data
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func keyInfo() async throws -> KeyInfo {
        let data = try await Self.send(authorized(URLRequest(url: Self.baseURL.appending(path: "key"))))
        return try JSONDecoder().decode(DataEnvelope<KeyInfo>.self, from: data).data
    }

    /// Sends audio as base64 JSON and asks for timestamps (`verbose_json`).
    func transcribe(audio: Data, format: String, model: String, language: String?) async throws -> Transcription {
        var body: [String: Any] = [
            "model": model,
            "input_audio": ["data": audio.base64EncodedString(), "format": format],
            "response_format": "verbose_json",
        ]
        if let language, !language.isEmpty { body["language"] = language }

        var request = authorized(URLRequest(url: Self.baseURL.appending(path: "audio/transcriptions")))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 600
        let data = try await Self.send(request)
        return try JSONDecoder().decode(Transcription.self, from: data)
    }

    private func authorized(_ request: URLRequest) -> URLRequest {
        var request = request
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("Bacisc Video Editor", forHTTPHeaderField: "X-Title")
        return request
    }

    /// Performs the request; non-2xx responses become `ClientError.http` with OpenRouter's message.
    private static func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error.message
                ?? String(data: data, encoding: .utf8)
                ?? HTTPURLResponse.localizedString(forStatusCode: status)
            throw ClientError.http(status: status, message: message)
        }
        return data
    }

    private struct DataEnvelope<Value: Decodable>: Decodable {
        let data: Value
    }

    private struct ErrorEnvelope: Decodable {
        struct Body: Decodable {
            let message: String
        }

        let error: Body
    }
}
