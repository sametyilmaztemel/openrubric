#if os(macOS)
import AppKit

// Programmatic entry point (no nib): keep the app alive in the menu bar
// until the user quits from the status item menu.
let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
#endif
