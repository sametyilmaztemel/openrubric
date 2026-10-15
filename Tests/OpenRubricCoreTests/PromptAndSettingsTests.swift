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
    @Test("defaults target Anthropic Claude Haiku")
    func defaults() {
        let s = OpenRubricSettings()
        #expect(s.apiProvider == .anthropic)
        #expect(s.baseURL == "https://api.anthropic.com")
        #expect(s.model == "claude-haiku-5-5")
        #expect(s.promptMode == .multipleChoice)
    }

    @Test("provider switch updates default endpoint and model")
    func providerSwitch() {
        let openAI = OpenRubricSettings(apiProvider: .openAICompatible)
        #expect(openAI.baseURL == "https://api.openai.com/v1")
        #expect(openAI.model == "gpt-4o-mini")
        let anthropic = OpenRubricSettings(apiProvider: .anthropic)
        #expect(anthropic.baseURL == "https://api.anthropic.com")
    }

    @Test("Codable round-trip preserves all fields")
    func roundTrip() throws {
        let original = OpenRubricSettings(
            apiProvider: .anthropic,
            baseURL: "https://api.minimax.io/anthropic",
            model: "claude-haiku-5-5",
            promptMode: .shortAnswer,
            includeExplanation: false,
            cropRadius: 120
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(OpenRubricSettings.self, from: data)
        #expect(decoded == original)
        #expect(decoded.cropRadius == 120)
    }

    @Test("makeClient builds an AnthropicClient for the anthropic provider")
    func makeClientAnthropic() throws {
        let s = OpenRubricSettings()
        let client = try s.makeClient(apiKey: "sk-test")
        let anthropic = client as? AnthropicClient
        #expect(anthropic != nil)
        #expect(anthropic!.configuration.model == "claude-haiku-5-5")
        #expect(anthropic!.configuration.baseURL == "https://api.anthropic.com")
    }

    @Test("makeClient builds an OpenAICompatibleClient for the openAI provider")
    func makeClientOpenAI() throws {
        let s = OpenRubricSettings(apiProvider: .openAICompatible)
        let client = try s.makeClient(apiKey: "sk-test")
        let openAI = client as? OpenAICompatibleClient
        #expect(openAI != nil)
        #expect(openAI!.configuration.model == "gpt-4o-mini")
    }

    @Test("named providers (OpenAI, DeepSeek) route to the OpenAI-compatible client")
    func namedProvidersRouteToOpenAICompatible() throws {
        let openai = OpenRubricSettings(apiProvider: .openAI)
        #expect(openai.baseURL == "https://api.openai.com/v1")
        #expect(openai.model == "gpt-4o-mini")
        let oaiClient = try openai.makeClient(apiKey: "sk-test")
        #expect((oaiClient as? OpenAICompatibleClient) != nil)

        let deepseek = OpenRubricSettings(apiProvider: .deepseek)
        #expect(deepseek.baseURL == "https://api.deepseek.com")
        #expect(deepseek.model == "deepseek-flash")
        let dClient = try deepseek.makeClient(apiKey: "sk-test")
        let d = dClient as? OpenAICompatibleClient
        #expect(d != nil)
        #expect(d!.configuration.baseURL == "https://api.deepseek.com")
        #expect(d!.configuration.model == "deepseek-flash")
    }

    @Test("a saved v2 settings payload without the new cases still decodes")
    func backwardsCompatDecode() throws {
        // Payload written before .openAI / .deepseek existed (only the two
        // original raw values are legal). Decoding it must not fail.
        let legacy = """
        {"apiProvider":"anthropic","baseURL":"https://api.anthropic.com","model":"claude-haiku-5-5","promptMode":"multipleChoice","includeExplanation":true,"cropRadius":260,"flashChannels":["capsLockLED"]}
        """
        let decoded = try JSONDecoder().decode(OpenRubricSettings.self, from: Data(legacy.utf8))
        #expect(decoded.apiProvider == .anthropic)
        #expect(decoded.baseURL == "https://api.anthropic.com")
    }
}