import Foundation

/// Builds the system prompt and user prompt for the vision call.
///
/// The contract with the model:
/// - multiple choice -> single letter
/// - short answer -> at most two sentences
/// - optional one-sentence explanation
public enum PromptBuilder {

    public static func systemPrompt(mode: PromptMode, includeExplanation: Bool) -> String {
        var lines: [String] = []
        lines.append("You are a precise exam assistant. A crop of the screen around the user's cursor contains an exam question.")
        switch mode {
        case .multipleChoice:
            lines.append("Find the single correct option among the listed choices. Do not guess: if the question or the options are not visible in the crop, say so in the explanation and set the confidence to low.")
        case .shortAnswer:
            lines.append("Answer the question concisely, in at most two sentences, using the language of the question.")
        }
        if includeExplanation {
            lines.append("After the answer, add a short explanation (at most one sentence).")
        } else {
            lines.append("Do not add any explanation.")
        }
        return lines.joined(separator: "\n")
    }

    public static func userPrompt(mode: PromptMode, includeExplanation: Bool) -> String {
        let format: String
        switch mode {
        case .multipleChoice:
            format = includeExplanation
                ? "ANSWER: <single letter>\nCONFIDENCE: <high|medium|low>\nEXPLANATION: <one sentence>"
                : "ANSWER: <single letter>\nCONFIDENCE: <high|medium|low>"
        case .shortAnswer:
            format = includeExplanation
                ? "ANSWER: <at most two sentences>\nCONFIDENCE: <high|medium|low>\nEXPLANATION: <one sentence>"
                : "ANSWER: <at most two sentences>\nCONFIDENCE: <high|medium|low>"
        }
        return "Answer the question visible in this image. Respond exactly in this format:\n" + format
    }
}
