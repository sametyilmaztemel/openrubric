import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// OpenAI-compatible chat completion endpoint (OpenAI, Groq, Together,
/// OpenRouter, local Ollama, vLLM, ...). No vendor lock-in: any
/// `POST {baseUrl}/chat/completions` that accepts an `image_url` content
/// part works.
public protocol ChatCompletionsClient: Sendable {
    /// Sends one chat completion turn with an image (base64 PNG) and
    /// returns the assistant message content plus token usage when the
    /// provider reports it.
    func completion(systemPrompt: String, userPrompt: String, imagePNG: Data) async throws -> CompletionResult
}

/// `URLSession` is immutable here and thread-safe for concurrent requests,
/// hence `@unchecked` (Swift's libcurl-based session is not marked Sendable).
public struct OpenAICompatibleClient: ChatCompletionsClient, @unchecked Sendable {
    public struct Configuration: Sendable {
        /// e.g. `https://api.openai.com/v1`, `http://localhost:11434/v1`
        public var baseURL: String
        /// API key (any OpenAI-compatible scheme; Ollama accepts a dummy).
        public var apiKey: String
        /// Model id, e.g. `gpt-4o-mini`, `llama3.2-vision`.
        public var model: String
        /// Maximum tokens for the assistant message.
        public var maxTokens: Int

        public init(baseURL: String, apiKey: String, model: String, maxTokens: Int = 300) {
            self.baseURL = baseURL
            self.apiKey = apiKey
            self.model = model
            self.maxTokens = maxTokens
        }
    }

    public enum Error: LocalizedError {
        case invalidBaseURL(String)
        case http(status: Int, body: String)
        case decoding(String)
        case emptyContent

        public var errorDescription: String? {
            switch self {
            case .invalidBaseURL(let url):
                return "Invalid base URL: \"\(url.prefix(80))\" (expected e.g. https://api.openai.com/v1)"
            case .http(let status, let body):
                return "HTTP \(status): \(body.prefix(300))"
            case .decoding(let detail):
                return "Response decoding failed: \(detail)"
            case .emptyContent:
                return "Model returned no content"
            }
        }
    }

    public let configuration: Configuration
    /// Injected for tests; default is `URLSession.shared`.
    public let session: URLSession
    /// Resolved `POST` target.
    let url: URL

    public init(configuration: Configuration, session: URLSession = .shared) throws {
        self.configuration = configuration
        self.session = session
        // Settings come from a plain text field: trim before parsing so
        // " https://api.openai.com/v1 " does not crash the app. Trailing
        // slashes and query strings are handled by path-level resolution.
        let trimmed = configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              components.scheme != nil, components.host != nil else {
            throw Error.invalidBaseURL(configuration.baseURL)
        }
        var path = components.pathString
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path + "/chat/completions"
        guard let resolved = components.url else {
            throw Error.invalidBaseURL(configuration.baseURL)
        }
        self.url = resolved
    }

    public func completion(systemPrompt: String, userPrompt: String, imagePNG: Data) async throws -> CompletionResult {
        let body: [String: Any] = [
            "model": configuration.model,
            "max_tokens": configuration.maxTokens,
            "messages": [
                ["role": "system", "content": systemPrompt],
                [
                    "role": "user",
                    "content": [
                        ["type": "image_url", "image_url": [
                            "url": "data:image/png;base64,\(imagePNG.base64EncodedString())"
                        ]],
                        ["type": "text", "text": userPrompt],
                    ],
                ],
            ],
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        // Exam use: a stale answer is worse than no answer.
        request.timeoutInterval = 30

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Error.decoding("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Error.http(status: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"] as? String
        else {
            throw Error.decoding(String(decoding: data.prefix(500), as: UTF8.self))
        }
        guard !content.isEmpty else {
            throw Error.emptyContent
        }
        return CompletionResult(text: content, usage: parseUsage(from: json))
    }

    /// OpenAI-compatible usage block: `prompt_tokens` / `completion_tokens`.
    private func parseUsage(from json: [String: Any]) -> TokenUsage? {
        guard let usage = json["usage"] as? [String: Any] else { return nil }
        let prompt = (usage["prompt_tokens"] as? NSNumber)?.intValue
        let completion = (usage["completion_tokens"] as? NSNumber)?.intValue
        guard let prompt, let completion else { return nil }
        return TokenUsage(inputTokens: prompt, outputTokens: completion)
    }
}
