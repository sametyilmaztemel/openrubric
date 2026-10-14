import Foundation

/// Question type used for prompt building and answer parsing.
public enum PromptMode: String, CaseIterable, Codable, Sendable {
    /// Multiple choice: the model must return a single letter.
    case multipleChoice
    /// Short / free-form answer.
    case shortAnswer
}

/// Mode accepted by `AnswerParser`. `.auto` classifies the model output.
public enum ParserMode: Sendable {
    /// Single A-Z character is treated as a letter, anything else as text.
    case auto
    /// Force letter extraction (exam context is multiple choice).
    case multipleChoice
    /// Never treat the output as a letter.
    case shortAnswer

    public init(promptMode: PromptMode?) {
        switch promptMode {
        case .multipleChoice: self = .multipleChoice
        case .shortAnswer: self = .shortAnswer
        case nil: self = .auto
        }
    }
}

/// Structured answer produced from raw model output.
public struct ParsedAnswer: Equatable, Sendable {
    public enum Confidence: String, CaseIterable, Sendable {
        case high
        case medium
        case low
    }

    /// Single uppercase letter for multiple choice; `nil` for short answers.
    public let letter: String?
    /// Normalized answer text (the letter itself for multiple choice).
    public let text: String
    public let confidence: Confidence
    public let explanation: String?

    public init(letter: String?, text: String, confidence: Confidence, explanation: String?) {
        self.letter = letter
        self.text = text
        self.confidence = confidence
        self.explanation = explanation
    }

    public var isMultipleChoice: Bool { letter != nil }
}

/// Lenient parser for the model's structured answer contract:
///
/// ```
/// ANSWER: <letter or short text>
/// CONFIDENCE: <high|medium|low>
/// EXPLANATION: <one sentence>
/// ```
///
/// Accepts case/whitespace/bold variations, bare letters, and
/// "The answer is B." style outputs. Never throws: bad input yields an
/// empty `ParsedAnswer` (empty text, `medium` confidence).
public enum AnswerParser {

    public static func parse(_ raw: String, mode: ParserMode = .auto) -> ParsedAnswer {
        let cleaned = stripCodeFences(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        let lines = cleaned.components(separatedBy: .newlines)

        var answerValue: String?
        var confidence = ParsedAnswer.Confidence.medium
        var explanation: String?

        var index = 0
        while index < lines.count {
            let line = lines[index]
            if let (key, value) = keyLine(line) {
                switch key {
                case "answer":
                    if answerValue == nil {
                        answerValue = value.isEmpty
                            ? nextNonEmptyLine(after: index, in: lines)
                            : value
                    }
                case "confidence":
                    if let c = ParsedAnswer.Confidence(matching: stripEmphasis(value)) {
                        confidence = c
                    }
                case "explanation":
                    var text = stripEmphasis(value)
                    var j = index + 1
                    while j < lines.count, keyLine(lines[j]) == nil {
                        let continuation = lines[j].trimmingCharacters(in: .whitespaces)
                        if continuation.isEmpty { break }
                        text += (text.isEmpty ? "" : " ") + stripEmphasis(continuation)
                        j += 1
                    }
                    if !text.isEmpty { explanation = text }
                default:
                    break
                }
            }
            index += 1
        }

        if answerValue == nil {
            // Fallback: first non-empty line that is not a key line.
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty, keyLine(trimmed) == nil {
                    answerValue = trimmed
                    break
                }
            }
        }

        let value = normalize(answerValue ?? "")
        let letter = extractLetter(from: value, mode: mode)
        return ParsedAnswer(
            letter: letter,
            text: value,
            confidence: confidence,
            explanation: explanation
        )
    }

    // MARK: - Internals

    /// Splits a line into (lowercase key, value) if it looks like "KEY: value".
    /// Turkish keys (cevap/güven/açıklama) are accepted too. Emphasis around
    /// the key (`**answer**`) is ignored.
    private static func keyLine(_ line: String) -> (key: String, value: String)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let rawKey = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
        let key = stripEmphasis(rawKey).lowercased()
        switch key {
        case "answer", "cevap":
            return ("answer", String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
        case "confidence", "güven", "guven":
            return ("confidence", String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
        case "explanation", "açıklama", "aciklama":
            return ("explanation", String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
        default:
            return nil
        }
    }

    private static func nextNonEmptyLine(after index: Int, in lines: [String]) -> String? {
        var j = index + 1
        while j < lines.count {
            let trimmed = lines[j].trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, keyLine(trimmed) == nil { return trimmed }
            j += 1
        }
        return nil
    }

    private static func stripCodeFences(_ s: String) -> String {
        var t = s
        if t.hasPrefix("```") {
            t = String(t.dropFirst(3))
            if let nl = t.firstIndex(of: "\n") { t.removeSubrange(t.startIndex...nl) }
            if t.hasSuffix("```") { t = String(t.dropLast(3)) }
        }
        return t
    }

    /// Strips markdown emphasis, quotes, "The answer is ..." wrappers,
    /// surrounding parens and trailing punctuation.
    private static func normalize(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespaces)
        // "The answer is B" / "Answer: B" style wrappers.
        if let m = t.range(of: #"(?is)^(?:the\s+)?(?:answer|cevap)\s*(?:is|:)\s*(.+)$"#, options: .regularExpression) {
            t = String(t[m]).trimmingCharacters(in: .whitespaces)
        }
        t = stripEmphasis(t)
        // Trailing sentence punctuation.
        while let last = t.last, ".!?.\"'".contains(last) { t.removeLast() }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// Removes markdown emphasis / code / quote markers from both ends.
    private static func stripEmphasis(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespaces)
        let markers = ["**", "`", "*", "_", "\"", "'", "(", ")", "[", "]"]
        var changed = true
        while changed, !t.isEmpty {
            changed = false
            for m in markers where t.hasPrefix(m) {
                t.removeFirst(m.count); changed = true
            }
            for m in markers where t.hasSuffix(m) {
                t.removeLast(m.count); changed = true
            }
        }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// Extracts a single uppercase letter depending on mode.
    private static func extractLetter(from value: String, mode: ParserMode) -> String? {
        guard !value.isEmpty else { return nil }
        let chars = Array(value)
        // Single character A-Z (case-insensitive).
        if chars.count == 1,
           let c = chars.first,
           let ascii = c.asciiValue,
           (65...90).contains(ascii) || (97...122).contains(ascii) {
            return String(c).uppercased()
        }
        if mode == .multipleChoice {
            // "Option B" / "b." style: first standalone letter (case-insensitive).
            if let m = value.range(of: #"\b([A-Z])\b"#, options: [.regularExpression, .caseInsensitive]) {
                return String(value[m]).first.map { String($0).uppercased() }
            }
        }
        return nil
    }
}

extension ParsedAnswer.Confidence {
    init?(matching raw: String) {
        let t = raw.lowercased().trimmingCharacters(in: .whitespaces)
        // Turkish synonyms (the parser accepts Turkish keys too).
        let normalized: String
        switch t {
        case "yüksek", "yuksek", "certain":
            normalized = "high"
        case "orta", "moderate":
            normalized = "medium"
        case "düşük", "dusuk":
            normalized = "low"
        default:
            normalized = t
        }
        for c in ParsedAnswer.Confidence.allCases where normalized.hasPrefix(c.rawValue) {
            self = c
            return
        }
        return nil
    }
}
