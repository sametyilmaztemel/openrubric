import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Which API dialect the app talks to.
public enum ApiProvider: String, Codable, CaseIterable, Sendable {
    /// Anthropic Messages API (api.anthropic.com or an Anthropic-compatible
    /// proxy such as https://api.minimax.io/anthropic).
    case anthropic
    /// OpenAI Chat Completions (api.openai.com) — vision-capable models.
    case openAI
    /// DeepSeek (api.deepseek.com), OpenAI-compatible — cheap vision models.
    case deepseek
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
    /// When true, the parsed answer is also shown in a floating panel near
    /// the cursor. When false, only the discreet channels (LED/pulses) fire.
    public var showAnswerPopup: Bool
    /// Discreet output channels that fire after a multiple-choice answer.
    public var flashChannels: Set<FlashChannel>

    /// Backwards-compatible decode: fields added across schema versions
    /// (`flashChannels` in v2, `showAnswerPopup` in v3) fall back to their
    /// defaults when a saved payload predates them, so any stored settings
    /// JSON decodes without a `keyNotFound` error. (The app-layer migration
    /// also handles this for UserDefaults; this keeps the struct itself
    /// robust when decoded directly.)
    public init(from decoder: Decoder) throws {
        let c = decoder.container(keyedBy: CodingKeys.self)
        self.apiProvider = try c.decodeIfPresent(ApiProvider.self, forKey: .apiProvider) ?? .anthropic
        let provider = self.apiProvider
        self.baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? Self.defaultBaseURL(for: provider)
        self.model = try c.decodeIfPresent(String.self, forKey: .model) ?? Self.defaultModel(for: provider)
        self.promptMode = try c.decodeIfPresent(PromptMode.self, forKey: .promptMode) ?? .multipleChoice
        self.includeExplanation = try c.decodeIfPresent(Bool.self, forKey: .includeExplanation) ?? true
        self.cropRadius = try c.decodeIfPresent(CGFloat.self, forKey: .cropRadius) ?? 260
        self.showAnswerPopup = try c.decodeIfPresent(Bool.self, forKey: .showAnswerPopup) ?? true
        self.flashChannels = try c.decodeIfPresent(Set<FlashChannel>.self, forKey: .flashChannels) ?? [.capsLockLED]
    }

    public init(
        apiProvider: ApiProvider = .anthropic,
        baseURL: String? = nil,
        model: String? = nil,
        promptMode: PromptMode = .multipleChoice,
        includeExplanation: Bool = true,
        cropRadius: CGFloat = 260,
        showAnswerPopup: Bool = true,
        flashChannels: Set<FlashChannel> = [.capsLockLED]
    ) {
        self.apiProvider = apiProvider
        self.baseURL = baseURL ?? Self.defaultBaseURL(for: apiProvider)
        self.model = model ?? Self.defaultModel(for: apiProvider)
        self.promptMode = promptMode
        self.includeExplanation = includeExplanation
        self.cropRadius = cropRadius
        self.showAnswerPopup = showAnswerPopup
        self.flashChannels = flashChannels
    }

    /// The Messages API endpoint, not an OpenAI-style `/v1` URL.
    public static func defaultBaseURL(for provider: ApiProvider) -> String {
        switch provider {
        case .anthropic:
            return "https://api.anthropic.com"
        case .openAI:
            return "https://api.openai.com/v1"
        case .deepseek:
            return "https://api.deepseek.com"
        case .openAICompatible:
            return "https://api.openai.com/v1"
        }
    }

    public static func defaultModel(for provider: ApiProvider) -> String {
        switch provider {
        case .anthropic:
            return "claude-haiku-5-5"
        case .openAI:
            return "gpt-4o-mini"
        case .deepseek:
            return "deepseek-flash"
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
        case .openAI, .deepseek, .openAICompatible:
            return try OpenAICompatibleClient(
                configuration: .init(baseURL: baseURL, apiKey: apiKey, model: model),
                session: session
            )
        }
    }
}
