import AppKit

/// An ink-tight template, centered by the native status button. The system owns
/// the surrounding hit target and selected/light/dark appearance.
@MainActor
final class MenuBarArtwork {
    static let width: CGFloat = 34
    private let symbol = NSImage(systemSymbolName: "fanblades.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16, weight: .medium))
    private let attributes: [NSAttributedString.Key: Any] = {
        let base = NSFont.monospacedDigitSystemFont(ofSize: 7.5, weight: .semibold)
        let descriptor = base.fontDescriptor.addingAttributes([
            .traits: [NSFontDescriptor.TraitKey.width: -0.2]
        ])
        return [.font: NSFont(descriptor: descriptor, size: 7.5) ?? base,
                .foregroundColor: NSColor.white]
    }()

    func image(for metric: MenuBarMetric) -> NSImage {
        let parts = metric.title.split(separator: " ", maxSplits: 1)
        let value = parts.count == 2 ? String(parts[1]) : metric.title
        let image = NSImage(size: NSSize(width: Self.width, height: 18))
        image.lockFocus()

        // SF Symbols carry their own optical margins. This 20pt drawing box
        // produces a ~16pt fan, centered on the two 9pt text rows. The old
        // 11.5pt drawing box produced only a ~9pt visible fan.
        symbol?.draw(in: NSRect(x: -2, y: -1, width: 20, height: 20),
                     from: .zero, operation: .sourceOver, fraction: 1)
        draw(metric.menuBarLabel, y: 9)
        draw(value, y: 0)
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    private func draw(_ text: String, y: CGFloat) {
        let text = text as NSString
        let width = text.size(withAttributes: attributes).width
        // Reserve the widest value (100%) so metric cycling never moves the
        // neighboring items. Center shorter labels in that same compact column.
        let x = 15.5 + max(0, (18.5 - width) / 2)
        text.draw(at: NSPoint(x: (x * 2).rounded() / 2, y: y), withAttributes: attributes)
    }
}
