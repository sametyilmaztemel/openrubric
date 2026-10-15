#if os(macOS)
import AppKit
import OpenRubricCore

/// A small window listing the recent answers with their token usage and
/// cost. Read-only; the "Clear" button resets the store.
@MainActor
final class HistoryWindowController: NSWindowController {
    private let store: HistoryStore
    private let tableView = NSTableView()
    private var entries: [HistoryEntry] = []
    private let limit = 50

    /// Shared time formatter (hoisted out of per-cell allocation).
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    init(store: HistoryStore) {
        self.store = store
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 340),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "OpenRubric — History"
        window.center()
        super.init(window: window)
        buildUI()
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        let scroll = NSScrollView(frame: contentView.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true

        let dateCol = NSTableColumn(identifier: .init("date"))
        dateCol.title = "Time"
        dateCol.width = 110
        let answerCol = NSTableColumn(identifier: .init("answer"))
        answerCol.title = "Answer"
        answerCol.width = 80
        let textCol = NSTableColumn(identifier: .init("text"))
        textCol.title = "Answer text"
        textCol.width = 180
        let modelCol = NSTableColumn(identifier: .init("model"))
        modelCol.title = "Model"
        modelCol.width = 110
        let costCol = NSTableColumn(identifier: .init("cost"))
        costCol.title = "Cost (USD)"
        costCol.width = 90
        let columns = [dateCol, answerCol, textCol, modelCol, costCol]

        tableView.usesAlternatingRowBackgroundColors = true
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        for col in columns {
            tableView.addTableColumn(col)
        }
        tableView.dataSource = self
        tableView.delegate = self
        scroll.documentView = tableView
        contentView.addSubview(scroll)

        let bottom = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 28))
        bottom.autoresizingMask = [.width, .minYMargin]
        let clearButton = NSButton(title: "Clear History", target: self, action: #selector(clear))
        clearButton.bezelStyle = .rounded
        clearButton.sizeToFit()
        clearButton.frame.origin = NSPoint(x: 10, y: 4)
        bottom.addSubview(clearButton)
        let totalLabel = NSTextField(labelWithString: "")
        totalLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        totalLabel.frame = NSRect(x: 150, y: 6, width: 350, height: 18)
        totalLabel.autoresizingMask = [.minXMargin]
        bottom.addSubview(totalLabel)
        self.totalLabel = totalLabel
        // position above the window's bottom edge
        bottom.frame.origin = NSPoint(x: 0, y: 0)
        contentView.addSubview(bottom)
    }

    private var totalLabel: NSTextField?

    override func showWindow(_ sender: Any?) {
        reload()
        super.showWindow(sender)
    }

    private func reload() {
        entries = store.entries(limit: limit)
        tableView.reloadData()
        let total = entries.compactMap(\.costUSD).reduce(0, +)
        totalLabel?.stringValue = "Total of last \(entries.count) answers: \(String(format: "$%.4f", total))"
    }

    @objc private func clear() {
        store.clear()
        reload()
    }
}

extension HistoryWindowController: NSTableViewDataSource, NSTableViewDelegate {
    nonisolated func numberOfRows(in tableView: NSTableView) -> Int {
        MainActor.assumeIsolated { self.entries.count }
    }

    nonisolated func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        MainActor.assumeIsolated {
            guard let colID = tableColumn?.identifier.rawValue, row < self.entries.count else { return nil }
            let entry = self.entries[row]
            let id = NSUserInterfaceItemIdentifier("cell-\(colID)-\(row)")
            let cell: NSTextField
            if let reused = tableView.makeView(withIdentifier: id, owner: self) as? NSTextField {
                cell = reused
            } else {
                cell = NSTextField(labelWithString: "")
                cell.identifier = id
                cell.font = NSFont.systemFont(ofSize: 11)
                cell.lineBreakMode = .byTruncatingTail
            }
            let formatter = Self.timeFormatter
            switch colID {
            case "date":
                cell.stringValue = formatter.string(from: entry.timestamp)
            case "answer":
                cell.stringValue = entry.letter ?? "—"
            case "text":
                cell.stringValue = entry.answer
            case "model":
                cell.stringValue = entry.model
            case "cost":
                cell.stringValue = entry.costUSD.map { String(format: "$%.4f", $0) } ?? "—"
            default:
                cell.stringValue = ""
            }
            return cell
        }
    }
}
#endif
