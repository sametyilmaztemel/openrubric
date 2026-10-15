import Foundation

/// One recorded answer: the question image is NOT stored (privacy: exam
/// screenshots may contain identifying content), only the parsed answer,
/// the model, and token accounting.
public struct HistoryEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var timestamp: Date
    public var answer: String
    public var letter: String?
    public var model: String
    public var usage: TokenUsage?
    /// USD cost of the turn; `nil` when the pricing table is unknown.
    public var costUSD: Double?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        answer: String,
        letter: String? = nil,
        model: String,
        usage: TokenUsage? = nil,
        costUSD: Double? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.answer = answer
        self.letter = letter
        self.model = model
        self.usage = usage
        self.costUSD = costUSD
    }
}

/// Append-only JSON-lines history store (one `HistoryEntry` per line).
///
/// JSONL is chosen over SQLite: the data volume is tiny (a few KB per
/// exam), the format is human-inspectable, and the core target has no
/// dependencies. Writes are guarded by an internal serial queue.
public final class HistoryStore: @unchecked Sendable {
    private let url: URL
    private let queue = DispatchQueue(label: "openrubric.history")

    public init(fileURL: URL) {
        self.url = fileURL
    }

    /// The most recent entries, newest first. A missing or corrupt file
    /// is not an error - it yields an empty history.
    public func entries(limit: Int? = nil) -> [HistoryEntry] {
        queue.sync {
            guard let data = try? Data(contentsOf: url) else { return [] }
            let lines = String(decoding: data, as: UTF8.self)
                .split(separator: "\n", omittingEmptySubsequences: true)
            var entries: [HistoryEntry] = []
            for line in lines {
                if let entry = try? JSONDecoder().decode(HistoryEntry.self, from: Data(line.utf8)) {
                    entries.append(entry)
                }
            }
            // Newest first; trim to the requested limit.
            let newest = entries.reversed()
            if let limit {
                return Array(newest.prefix(limit))
            }
            return Array(newest)
        }
    }

    /// Appends an entry. Creates the parent directory on first write.
    public func record(_ entry: HistoryEntry) throws {
        try queue.sync {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let line = try JSONEncoder().encode(entry)
            var data = Data()
            data.append(line)
            data.append("\n".data(using: .utf8)!)
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: url, options: .atomic)
            }
        }
    }

    /// Removes all history.
    public func clear() {
        queue.sync {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
