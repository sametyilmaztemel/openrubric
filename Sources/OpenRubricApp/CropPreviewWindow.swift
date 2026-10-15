#if os(macOS)
import AppKit

/// A small, non-modal window that shows the cursor-centred crop OpenRubric
/// would send to the model. Lets the user confirm the question (and its
/// answer choices) are actually inside the captured region before they
/// trigger a paid answer — the fix for "the model didn't see the options".
@MainActor
final class CropPreviewWindow: NSWindow {
    init(image: NSImage, radius: Int) {
        // Cap the displayed size so a large radius does not open a
        // full-screen window.
        let maxSide: CGFloat = 720
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)

        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        title = "Crop preview (\(radius) pt radius) — model sees this"
        isReleasedWhenClosed = false

        let imageView = NSImageView()
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        let content = contentView!
        content.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            imageView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            imageView.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            imageView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
        ])

        center()
        level = .floating
        isMovableByWindowBackground = true
    }
}
#endif
