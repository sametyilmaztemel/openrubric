import Testing
import Foundation
@testable import OpenRubricCore

@Suite("AnswerParser — structured contract")
struct AnswerParserStructuredTests {
    @Test("parses canonical multiple-choice output")
    func canonicalMC() {
        let raw = """
        ANSWER: B
        CONFIDENCE: high
        EXPLANATION: Option B is the only value that satisfies the equation.
        """
        let a = AnswerParser.parse(raw, mode: .multipleChoice)
        #expect(a.letter == "B")
        #expect(a.text == "B")
        #expect(a.confidence == .high)
        #expect(a.explanation == "Option B is the only value that satisfies the equation.")
    }

    @Test("tolerates lowercase, bold and code fences")
    func tolerantFormatting() {
        let raw = "```markdown\n**answer**: **c**\n**confidence**: **Low**\n**explanation**: *see figure*\n```"
        let a = AnswerParser.parse(raw, mode: .multipleChoice)
        #expect(a.letter == "C")
        #expect(a.confidence == .low)
        #expect(a.explanation == "see figure")
    }

    @Test("parses short answer with multi-sentence answer")
    func shortAnswer() {
        let raw = """
        ANSWER: 42
        CONFIDENCE: medium
        """
        let a = AnswerParser.parse(raw, mode: .shortAnswer)
        #expect(a.letter == nil)
        #expect(a.text == "42")
        #expect(a.confidence == .medium)
    }
}

@Suite("AnswerParser — fallbacks")
struct AnswerParserFallbackTests {
    @Test("bare letter")
    func bareLetter() {
        let a = AnswerParser.parse("D", mode: .multipleChoice)
        #expect(a.letter == "D")
        #expect(a.confidence == .medium)
    }

    @Test("'The answer is B.' wrapper")
    func wrapper() {
        let a = AnswerParser.parse("The answer is B.", mode: .multipleChoice)
        #expect(a.letter == "B")
    }

    @Test("'Option C' phrasing in MC mode")
    func optionPhrasing() {
        let a = AnswerParser.parse("Option C", mode: .multipleChoice)
        #expect(a.letter == "C")
    }

    @Test("long text in auto mode is not treated as a letter")
    func autoModeLongText() {
        let a = AnswerParser.parse("The mitochondrion is the powerhouse of the cell.", mode: .auto)
        #expect(a.letter == nil)
        #expect(!a.text.isEmpty)
    }

    @Test("garbage input returns empty answer without throwing")
    func garbage() {
        let a = AnswerParser.parse("?!?", mode: .auto)
        #expect(a.text == "")
        #expect(a.letter == nil)
    }

    @Test("Turkish keys are accepted")
    func turkishKeys() {
        let raw = "CEVAP: A\nGÜVEN: yüksek"
        let a = AnswerParser.parse(raw, mode: .multipleChoice)
        #expect(a.letter == "A")
    }

    @Test("multi-line explanation is joined")
    func multiLineExplanation() {
        let raw = """
        ANSWER: A
        EXPLANATION: first part
        second part of the explanation
        """
        let a = AnswerParser.parse(raw, mode: .multipleChoice)
        #expect(a.explanation == "first part second part of the explanation")
    }
}
