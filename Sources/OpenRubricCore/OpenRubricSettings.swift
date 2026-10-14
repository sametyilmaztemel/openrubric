import Foundation

/// User-facing settings. Persisted by the app layer (UserDefaults +
/// Keychain for the API key); the core layer only knows the values.
public struct OpenRubricSettings: Codable, Equatable, Sendable {
    public var baseURL: String
    public var model: String
    public var promptMode: PromptMode
    public var includeExplanation: Bool
    /// Crop side is `2 * cropRadius` (points).
    public var cropRadius: CGFloat

    public init(
        baseURL: String = "https://api.openai.com/v1",
        model: String = "gpt-4o-mini",
        promptMode: PromptMode = .multipleChoice,
        includeExplanation: Bool = true,
        cropRadius: CGFloat = 260
    ) {
        self.baseURL = baseURL
        self.model = model
        self.promptMode = promptMode
        self.includeExplanation = includeExplanation
        self.cropRadius = cropRadius
    }

    public func clientConfiguration(apiKey: String) -> OpenAICompatibleClient.Configuration {
        OpenAICompatibleClient.Configuration(
            baseURL: baseURL,
            apiKey: apiKey,
            model: model
        )
    }
}
