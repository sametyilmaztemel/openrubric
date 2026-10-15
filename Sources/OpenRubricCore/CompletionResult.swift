import Foundation

/// Token accounting for one API turn, as reported by the provider.
///
/// Both fields are optional because some compatible providers omit the
/// `usage` object entirely; cost estimation degrades gracefully.
public struct TokenUsage: Codable, Equatable, Sendable {
    /// Prompt-side tokens (system + user text + image tokens).
    public var inputTokens: Int
    /// Completion-side tokens (assistant output).
    public var outputTokens: Int

    public init(inputTokens: Int, outputTokens: Int) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

/// A model provider's reply: the answer text plus token usage when the
/// response includes it.
public struct CompletionResult: Equatable, Sendable {
    public var text: String
    public var usage: TokenUsage?

    public init(text: String, usage: TokenUsage? = nil) {
        self.text = text
        self.usage = usage
    }
}
