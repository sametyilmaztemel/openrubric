#if os(macOS)
import Foundation

/// Appends the flash-chain diagnostics to a plain, `cat`-able log file.
///
/// Why a file instead of `NSLog`: on macOS 12 (Monterey) `log stream`
/// redacts NSLog message bodies as `(Foundation) <private>` and the
/// `--private` flag that would reveal them does not exist, so the flash
/// chain is effectively invisible in the system log. A file written with a
/// plain `String.write` sidesteps that entirely: the user can `cat` it or
/// open it from the "Flash Log…" menu item.
///
/// Thread-safe: the flashers call in from their own serial queues and the
/// model calls in from the main actor, so all writes are serialized through
/// a private queue and never interleave.
enum FlashDiagnostics {
    /// The log file, created on demand at first write.
    static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("OpenRubric", isDirectory: true)
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("flash.log")
    }

    private static let queue = DispatchQueue(label: "openrubric.flashlog")

    /// Appends one timestamped line. Never throws: a failed write (read-only
    /// Application Support, disk full) must not break the flash cycle, so it
    /// is best-effort by design.
    static func note(_ message: String) {
        let line = "\(Self.timestamp()) OpenRubric: \(message)\n"
        // A failed write is not worth surfacing: encode first and skip rather
        // than force-unwrap, because `data(using: .utf8)` returns nil for a
        // string with unpaired surrogates (which can reach here from LLM
        // output via `parsed.text.prefix(20)`), and a crash on the log queue
        // would break the flash cycle this class exists to support.
        guard let data = line.data(using: .utf8) else { return }
        queue.async {
            do {
                let fm = FileManager.default
                let dir = Self.url.deletingLastPathComponent()
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                if fm.fileExists(atPath: Self.url.path) {
                    let handle = try FileHandle(forWritingTo: Self.url)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    handle.write(data)
                } else {
                    try data.write(to: Self.url, options: .atomic)
                }
            } catch {
                // Best-effort: a write failure is not worth surfacing here.
            }
        }
    }

    /// The last `n` lines, for the "Flash Log…" menu item. Returns a
    /// placeholder when the file does not exist yet.
    static func lastLines(_ n: Int) -> String {
        queue.sync {
            let fm = FileManager.default
            guard fm.fileExists(atPath: Self.url.path),
                  let data = try? Data(contentsOf: Self.url),
                  let text = String(data: data, encoding: .utf8) else {
                return "(no flash activity yet — answer a multiple-choice question)"
            }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let tail = lines.suffix(n)
            return tail.joined(separator: "\n")
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }
}
#endif
