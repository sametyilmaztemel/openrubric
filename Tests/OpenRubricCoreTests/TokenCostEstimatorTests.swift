import Testing
import Foundation
@testable import OpenRubricCore

@Suite("TokenCostEstimator")
struct TokenCostEstimatorTests {
    @Test("resolves Claude Haiku family pricing")
    func haikuPricing() {
        let e = TokenCostEstimator.pricing(for: "claude-haiku-5-5")
        #expect(e != nil)
        #expect(e?.inputPerMillion == 1.0)
        #expect(e?.outputPerMillion == 5.0)
    }

    @Test("resolves model prefixes (sonnet, opus, gpt-4o-mini)")
    func prefixes() {
        #expect(TokenCostEstimator.pricing(for: "claude-sonnet-4-5")?.inputPerMillion == 3.0)
        #expect(TokenCostEstimator.pricing(for: "claude-opus-4-1")?.inputPerMillion == 15.0)
        #expect(TokenCostEstimator.pricing(for: "gpt-4o-mini")?.outputPerMillion == 0.60)
    }

    @Test("gpt-4o-mini does not shadow gpt-4o")
    func miniNotShadowed() {
        // "gpt-4o" family (not mini) must resolve to the gpt-4o price,
        // and the mini prefix must not match a bare "gpt-4o".
        let gpt4o = TokenCostEstimator.pricing(for: "gpt-4o")
        #expect(gpt4o?.inputPerMillion == 2.5)
        let mini = TokenCostEstimator.pricing(for: "gpt-4o-mini")
        #expect(mini?.inputPerMillion == 0.15)
    }

    @Test("unknown model yields nil pricing")
    func unknown() {
        #expect(TokenCostEstimator.pricing(for: "llama3.2-vision") == nil)
        #expect(TokenCostEstimator.pricing(for: "") == nil)
    }

    @Test("cost math: input and output billed separately per million")
    func costMath() {
        let e = TokenCostEstimator(inputPerMillion: 1.0, outputPerMillion: 5.0)
        // 1,000 input + 1,000 output = 1.0/1000 + 5.0/1000 = $0.006
        let cost = e.cost(of: TokenUsage(inputTokens: 1_000, outputTokens: 1_000))
        #expect(cost != nil)
        #expect(abs(cost! - 0.006) < 1e-9)
    }

    @Test("missing usage yields nil cost")
    func noUsage() {
        let e = TokenCostEstimator(inputPerMillion: 1.0, outputPerMillion: 5.0)
        #expect(e.cost(of: nil) == nil)
    }
}
