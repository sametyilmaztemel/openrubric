import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Which API dialect the app talks to.
public enum ApiProvider: String, Codable, CaseIterable, Sendable {
    /// Anthropic Messages API (api.anthropic.com or an Anthropic-compatible
    /// proxy such as https://api.minimax.io/anthropic).
    case anthropic
    /// OpenAI-compatible chat/completions (OpenAI, Groq, OpenRouter, Ollama, vLLM).
    case openAICompatible
}

/// User-facing settings. Persisted by the app layer (UserDefaults +
/// Keychain for the API key); the core layer only knows the values.
public struct OpenRubricSettings: Codable, Equatable, Sendable {
    public var apiProvider: ApiProvider
    public var baseURL: String
    public var model: String
    public var promptMode: PromptMode
    public var includeExplanation: Bool
    /// Crop side is `2 * cropRadius` (points).
    public var cropRadius: CGFloat
    /// Discreet output channels that fire after a multiple-choice answer.
    public var flashChannels: Set<FlashChannel>

    public init(
        apiProvider: ApiProvider = .anthropic,
        baseURL: String? = nil,
        model: String? = nil,
        promptMode: PromptMode = .multipleChoice,
        includeExplanation: Bool = true,
        cropRadius: CGFloat = 260,
        flashChannels: Set<FlashChannel> = [.capsLockLED]
    ) {
        self.apiProvider = apiProvider
        self.baseURL = baseURL ?? Self.defaultBaseURL(for: apiProvider)
        self.model = model ?? Self.defaultModel(for: apiProvider)
        self.promptMode = promptMode
        self.includeExplanation = includeExplanation
        self.cropRadius = cropRadius
        self.flashChannels = flashChannels
    }

    /// The Messages API endpoint, not an OpenAI-style `/v1` URL.
    public static func defaultBaseURL(for provider: ApiProvider) -> String {
        switch provider {
        case .anthropic:
            return "https://api.anthropic.com"
        case .openAICompatible:
            return "https://api.openai.com/v1"
        }
    }

    public static func defaultModel(for provider: ApiProvider) -> String {
        switch provider {
        case .anthropic:
            return "claude-haiku-5-5"
        case .openAICompatible:
            return "gpt-4o-mini"
        }
    }

    /// Builds the concrete client for the configured provider.
    /// The key comes from the Keychain at runtime — never persisted here.
    public func makeClient(session: URLSession = .shared, apiKey: String) throws -> ChatCompletionsClient {
        switch apiProvider {
        case .anthropic:
            return try AnthropicClient(
                configuration: .init(baseURL: baseURL, apiKey: apiKey, model: model),
                session: session
            )
        case .openAICompatible:
            return try OpenAICompatibleClient(
                configuration: .init(baseURL: baseURL, apiKey: apiKey, model: model),
                session: session
            )
        }
    }
}
