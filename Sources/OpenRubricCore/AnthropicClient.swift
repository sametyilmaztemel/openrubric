import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Anthropic Messages API client (`POST {baseURL}/v1/messages`).
///
/// Works against api.anthropic.com and any Anthropic-compatible proxy
/// (e.g. `https://api.minimax.io/anthropic`). Auth is via the `x-api-key`
/// header — no Bearer, no system-role message; the system prompt is a
/// top-level parameter and the image is a `base64` content block.
public struct AnthropicClient: ChatCompletionsClient, @unchecked Sendable {
    public struct Configuration: Sendable {
        /// e.g. `https://api.anthropic.com` (default) or
        /// `https://api.minimax.io/anthropic` for an Anthropic-compatible proxy.
        public var baseURL: String
        public var apiKey: String
        /// Model id, e.g. `claude-haiku-5-5`, `claude-sonnet-4-5`.
        public var model: String
        /// Required by the Messages API.
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
                return "Invalid base URL: \"\(url.prefix(80))\" (expected e.g. https://api.anthropic.com)"
            case .http(let status, let body):
                return "HTTP \(status): \(body.prefix(300))"
            case .decoding(let detail):
                return "Response decoding failed: \(detail)"
            case .emptyContent:
                return "Model returned no text content"
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
        // " https://api.anthropic.com " does not crash the app.
        let trimmed = configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              components.scheme != nil, components.host != nil else {
            throw Error.invalidBaseURL(configuration.baseURL)
        }
        var path = components.pathString
        while path.hasSuffix("/") { path.removeLast() }
        // Official API: https://api.anthropic.com        -> /v1/messages
        // Proxy already exposing /v1: .../anthropic/v1  -> /messages
        if path.hasSuffix("/v1") {
            components.path = path + "/messages"
        } else {
            components.path = path + "/v1/messages"
        }
        guard let resolved = components.url else {
            throw Error.invalidBaseURL(configuration.baseURL)
        }
        self.url = resolved
    }

    public func completion(systemPrompt: String, userPrompt: String, imagePNG: Data) async throws -> String {
        // Messages API shape: `system` is a top-level parameter; the image
        // is a base64 content block inside the user message.
        let body: [String: Any] = [
            "model": configuration.model,
            "max_tokens": configuration.maxTokens,
            "system": systemPrompt,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": "image/png",
                                "data": imagePNG.base64EncodedString(),
                            ],
                        ],
                        ["type": "text", "text": userPrompt],
                    ],
                ],
            ],
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue(configuration.apiKey, forHTTPHeaderField: "x-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        // Exam use: a stale answer is worse than no answer.
        request.timeoutInterval = 30

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Error.decoding("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = errorDetail(from: data) ?? String(decoding: data, as: UTF8.self)
            throw Error.http(status: http.statusCode, body: detail)
        }
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let blocks = json["content"] as? [[String: Any]]
        else {
            throw Error.decoding(String(decoding: data.prefix(500), as: UTF8.self))
        }
        let text = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        guard !text.isEmpty else {
            throw Error.emptyContent
        }
        return text
    }

    /// Anthropic errors arrive as `{"type":"error","error":{"type":...,"message":...}}`
    /// with the real reason in `error.message`.
    private func errorDetail(from data: Data) -> String? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = json["error"] as? [String: Any],
            let message = error["message"] as? String
        else { return nil }
        return message
    }
}
