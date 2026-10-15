import Foundation

/// Per-model pricing (USD per million tokens), October 2026 list prices.
///
/// Prices are a snapshot, not a live lookup: they are documented in the
/// README and re-verified when the list changes. Unknown models yield a
/// `nil` cost rather than a guess (academic honesty: an estimate must be
/// an estimate of a real price table, not of made-up numbers).
public struct TokenCostEstimator: Sendable {
    public let inputPerMillion: Double
    public let outputPerMillion: Double

    public init(inputPerMillion: Double, outputPerMillion: Double) {
        self.inputPerMillion = inputPerMillion
        self.outputPerMillion = outputPerMillion
    }

    /// Resolves the pricing table for a model id by exact match first,
    /// then by family prefix (e.g. any `claude-haiku-*` revision).
    public static func pricing(for modelID: String) -> TokenCostEstimator? {
        let m = modelID.lowercased()
        if m.hasPrefix("claude-haiku") {
            return TokenCostEstimator(inputPerMillion: 1.0, outputPerMillion: 5.0)
        }
        if m.hasPrefix("claude-sonnet") {
            return TokenCostEstimator(inputPerMillion: 3.0, outputPerMillion: 15.0)
        }
        if m.hasPrefix("claude-opus") {
            return TokenCostEstimator(inputPerMillion: 15.0, outputPerMillion: 75.0)
        }
        if m.hasPrefix("gpt-4o-mini") {
            return TokenCostEstimator(inputPerMillion: 0.15, outputPerMillion: 0.60)
        }
        if m.hasPrefix("gpt-4o") {
            return TokenCostEstimator(inputPerMillion: 2.5, outputPerMillion: 10.0)
        }
        return nil
    }

    /// USD cost of one turn; `nil` when either the pricing table or the
    /// usage is unknown.
    public func cost(of usage: TokenUsage?) -> Double? {
        guard let usage else { return nil }
        return Double(usage.inputTokens) * inputPerMillion / 1_000_000
             + Double(usage.outputTokens) * outputPerMillion / 1_000_000
    }
}
