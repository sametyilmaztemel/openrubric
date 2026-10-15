import Testing
import Foundation
@testable import OpenRubricCore

@Suite("HistoryStore")
struct HistoryStoreTests {
    private func tempURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("openrubric-history-tests", isDirectory: true)
        let url = dir.appendingPathComponent("\(UUID().uuidString).jsonl")
        return url
    }

    private func makeEntry(answer: String, offset: Int = 0) -> HistoryEntry {
        HistoryEntry(
            answer: answer,
            letter: answer.first.flatMap { String($0) },
            model: "claude-haiku-5-5",
            usage: TokenUsage(inputTokens: 100, outputTokens: 10),
            costUSD: 0.0001
        )
    }

    @Test("records and reads entries back, newest first")
    func roundtrip() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = HistoryStore(fileURL: url)
        let e1 = makeEntry(answer: "A")
        let e2 = makeEntry(answer: "B")
        try store.record(e1)
        try store.record(e2)
        let entries = store.entries()
        #expect(entries.count == 2)
        #expect(entries[0] == e2)   // newest first
        #expect(entries[1] == e1)
        // cost + usage preserved
        #expect(entries[0].costUSD == 0.0001)
        #expect(entries[0].usage == TokenUsage(inputTokens: 100, outputTokens: 10))
    }

    @Test("limit trims to the most recent N")
    func limit() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = HistoryStore(fileURL: url)
        for a in ["A", "B", "C", "D"] { try store.record(makeEntry(answer: a)) }
        let top2 = store.entries(limit: 2)
        #expect(top2.map(\.answer) == ["D", "C"])
    }

    @Test("missing file yields empty history, not an error")
    func missing() {
        let url = tempURL()
        let store = HistoryStore(fileURL: url)
        #expect(store.entries().isEmpty)
    }

    @Test("corrupt lines are skipped, valid lines survive")
    func corrupt() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let good = makeEntry(answer: "A")
        try HistoryStore(fileURL: url).record(good)
        // Append a corrupt line, then a second valid entry, directly to the file.
        let good2 = makeEntry(answer: "B")
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{not valid json\n".utf8))
        try handle.write(contentsOf: try JSONEncoder().encode(good2))
        try handle.write(contentsOf: "\n".data(using: .utf8)!)
        try handle.close()
        let entries = HistoryStore(fileURL: url).entries()
        #expect(entries.map(\.answer) == ["B", "A"])
    }

    @Test("clear removes all entries")
    func clear() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = HistoryStore(fileURL: url)
        try store.record(makeEntry(answer: "A"))
        store.clear()
        #expect(store.entries().isEmpty)
    }
}
