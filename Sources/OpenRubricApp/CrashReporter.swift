#if os(macOS)
import AppKit
import Darwin
import OpenRubricCore

/// Writes a crash report to Application Support/OpenRubric/crash.log on the
/// next launch whenever the app dies via a fatal signal (SIGSEGV, SIGABRT,
/// SIGBUS, SIGTRAP — e.g. a Swift runtime precondition `brk`) or an uncaught
/// Objective-C/Swift exception.
///
/// The signal handler is minimal and uses only async-signal-safe primitives
/// (write, kill, signal, backtrace), so installing
/// it cannot mask the real crash. The log is prefixed with a fixed marker so
/// the app can detect and surface "the app crashed before this launch", and
/// it carries a backtrace that `atos`/lldb can symbolicate against the
/// shipped binary.
///
/// Installed once at launch (`install()`), before any flasher is created.
enum CrashReporter {
    private static let crashLogURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("OpenRubric", isDirectory: true)
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("crash.log")
    }()

    private static let marker = "OpenRubric CRASH\n"
    private static let watchedSignals: [Int32] = [SIGSEGV, SIGABRT, SIGBUS, SIGTRAP, SIGILL, SIGFPE]

    /// Installs the signal + exception handlers. Idempotent.
    static func install() {
        // BSD signal() semantics on macOS: the handler persists across
        // delivery (no SA_RESETHAND), so we avoid the SDK-version-dependent
        // sigaction union member name and SA_NODEFAULT entirely.
        for sig in watchedSignals {
            _ = signal(sig, signalHandler)
        }
        NSSetUncaughtExceptionHandler { exception in
            Self.writeUncaught(exception)
        }
    }

    /// Reads a pending crash report (if any), returning its text and clearing
    /// the file so it is surfaced exactly once.
    static func takePendingReport() -> String? {
        guard let data = try? Data(contentsOf: crashLogURL) else { return nil }
        try? FileManager.default.removeItem(at: crashLogURL)
        let text = String(decoding: data, as: UTF8.self)
        return text.isEmpty ? nil : text
    }

    // MARK: - Handlers (async-signal-safe only)

    private static func signalHandler(_ signal: Int32) {
        var lines: [String] = [marker]
        lines.append("signal=\(signal) (\(Self.signalName(signal)))\n")
        lines.append("epoch=\(time(nil))\n")
        lines.append("backtrace:\n")
        // backtrace()/backtrace_symbols() are the standard way to capture the
        // frames in a signal handler; they only read process memory. On macOS
        // the buffer is `UnsafeMutablePointer<UnsafeMutableRawPointer?>?`.
        var buffer = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
        let n = buffer.withUnsafeMutableBufferPointer { bp -> Int32 in
            backtrace(bp.baseAddress, Int32(bp.count))
        }
        if n > 0, let symbols = backtrace_symbols(&buffer, n) {
            for i in 0..<Int(n) {
                // backtrace_symbols frames are optional CChar pointers on macOS.
                if let frame = symbols[i] {
                    lines.append(String(cString: frame) + "\n")
                }
            }
            free(symbols)
        }
        writeAll(lines.joined())

        // BSD signal() persists across delivery, so restore the default
        // disposition before re-raising to deliver the crash to the system and
        // avoid re-entering the handler (infinite loop).
        _ = signal(signal, SIG_DFL)
        kill(getpid(), signal)
    }

    private static func writeUncaught(_ exception: NSException) {
        let text = marker
            + "uncaught exception: \(exception.name.rawValue) reason=\(exception.reason ?? "")\n"
            + "epoch=\(time(nil))\n"
            + "callStack:\n"
            + exception.callStackSymbols.joined(separator: "\n") + "\n"
        writeAll(text)
    }

    /// Writes text to the crash log, creating the file if needed.
    private static func writeAll(_ text: String) {
        let path = crashLogURL.path
        var fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let bytes = Array(text.utf8)
        var written = 0
        while written < bytes.count {
            let n = Darwin.write(fd, bytes.withUnsafeBytes { $0.baseAddress!.advanced(by: written) }, bytes.count - written)
            guard n > 0 else { break }
            written += n
        }
    }

    private static func signalName(_ signal: Int32) -> String {
        switch signal {
        case SIGSEGV: return "SEGV (memory)"
        case SIGABRT: return "ABRT (abort/precondition)"
        case SIGBUS: return "BUS (bus error)"
        case SIGTRAP: return "TRAP (brk/precondition)"
        case SIGILL: return "ILL (illegal instruction)"
        case SIGFPE: return "FPE (math)"
        default: return "unknown"
        }
    }
}
#endif
