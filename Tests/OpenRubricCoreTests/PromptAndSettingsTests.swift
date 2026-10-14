import Testing
import Foundation
@testable import OpenRubricCore

@Suite("PromptBuilder")
struct PromptBuilderTests {
    @Test("multiple choice, explanation on: format includes all three fields")
    func mcWithExplanation() {
        let user = PromptBuilder.userPrompt(mode: .multipleChoice, includeExplanation: true)
        #expect(user.contains("ANSWER: <single letter>"))
        #expect(user.contains("CONFIDENCE: <high|medium|low>"))
        #expect(user.contains("EXPLANATION: <one sentence>"))
    }

    @Test("multiple choice, explanation off: no EXPLANATION field")
    func mcWithoutExplanation() {
        let user = PromptBuilder.userPrompt(mode: .multipleChoice, includeExplanation: false)
        #expect(!user.contains("EXPLANATION"))
        let system = PromptBuilder.systemPrompt(mode: .multipleChoice, includeExplanation: false)
        #expect(system.contains("Do not add any explanation"))
    }

    @Test("short answer asks for at most two sentences")
    func shortAnswer() {
        let user = PromptBuilder.userPrompt(mode: .shortAnswer, includeExplanation: true)
        #expect(user.contains("at most two sentences"))
    }
}

@Suite("OpenRubricSettings")
struct SettingsTests {
    @Test("defaults point at OpenAI")
    func defaults() {
        let s = OpenRubricSettings()
        #expect(s.baseURL == "https://api.openai.com/v1")
        #expect(s.model == "gpt-4o-mini")
        #expect(s.promptMode == .multipleChoice)
    }

    @Test("Codable round-trip preserves all fields")
    func roundTrip() throws {
        let original = OpenRubricSettings(
            baseURL: "http://localhost:11434/v1",
            model: "llama3.2-vision",
            promptMode: .shortAnswer,
            includeExplanation: false,
            cropRadius: 120
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(OpenRubricSettings.self, from: data)
        #expect(decoded == original)
        #expect(decoded.cropRadius == 120)
    }

    @Test("client configuration maps fields")
    func clientConfig() {
        let s = OpenRubricSettings()
        let c = s.clientConfiguration(apiKey: "sk-test")
        #expect(c.baseURL == s.baseURL)
        #expect(c.model == s.model)
        #expect(c.apiKey == "sk-test")
    }
}
