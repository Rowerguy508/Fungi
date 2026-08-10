import Cocoa

// MARK: - Fungi Theme (Droppy-inspired, mushroom-themed)

enum FungiTheme {
    // Backgrounds (forest floor → under the cap)
    static let canopy = NSColor(calibratedRed: 0.06, green: 0.07, blue: 0.10, alpha: 1.0)      // page
    static let humus = NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.15, alpha: 1.0)       // card
    static let mycelium = NSColor(calibratedRed: 0.14, green: 0.16, blue: 0.20, alpha: 1.0)    // raised
    static let bark = NSColor(calibratedRed: 0.20, green: 0.22, blue: 0.26, alpha: 1.0)       // header
    static let cap = NSColor(calibratedRed: 0.78, green: 0.42, blue: 0.30, alpha: 1.0)         // primary mushroom cap
    static let gill = NSColor(calibratedRed: 0.93, green: 0.86, blue: 0.72, alpha: 1.0)        // cream gills
    static let moss = NSColor(calibratedRed: 0.40, green: 0.78, blue: 0.52, alpha: 1.0)        // moss green
    static let spore = NSColor(calibratedRed: 0.95, green: 0.65, blue: 0.85, alpha: 1.0)        // pink spore
    static let ink = NSColor(calibratedWhite: 1.0, alpha: 1.0)
    static let mist = NSColor(calibratedWhite: 0.95, alpha: 0.62)
    static let fog = NSColor(calibratedWhite: 0.62, alpha: 1.0)
    static let whisper = NSColor(calibratedWhite: 0.45, alpha: 1.0)

    // Fonts
    static let display = NSFont.systemFont(ofSize: 28, weight: .heavy)
    static let title = NSFont.systemFont(ofSize: 18, weight: .semibold)
    static let subtitle = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let body = NSFont.systemFont(ofSize: 13, weight: .regular)
    static let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let tab = NSFont.systemFont(ofSize: 11, weight: .semibold)

    // Card sizing
    static let cardRadius: CGFloat = 14
    static let cardInset: CGFloat = 10
    static let pad: CGFloat = 14
}

/// NSVisualEffectView wrapper for Droppy-style glass cards.
final class GlassCard: NSVisualEffectView {
    init(frame: NSRect, material: NSVisualEffectView.Material = .popover, cornerRadius: CGFloat = FungiTheme.cardRadius) {
        super.init(frame: frame)
        self.material = material
        self.blendingMode = .behindWindow
        self.state = .active
        self.wantsLayer = true
        self.layer?.cornerRadius = cornerRadius
        self.layer?.masksToBounds = true
        self.layer?.borderWidth = 1
        self.layer?.borderColor = NSColor(calibratedWhite: 1.0, alpha: 0.08).cgColor
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// Big rounded "shroom" button used in the popover for primary actions.
final class ShroomButton: NSButton {
    init(title: String, icon: String = "", color: NSColor = FungiTheme.cap) {
        super.init(frame: .zero)
        self.title = icon.isEmpty ? title : "\(icon)  \(title)"
        self.bezelStyle = .inline
        self.isBordered = false
        self.font = FungiTheme.subtitle
        self.contentTintColor = color
        self.wantsLayer = true
        self.layer?.cornerRadius = 12
        self.layer?.backgroundColor = NSColor(calibratedWhite: 1.0, alpha: 0.06).cgColor
        self.layer?.borderColor = color.withAlphaComponent(0.25).cgColor
        self.layer?.borderWidth = 1
    }
    required init?(coder: NSCoder) { fatalError() }
    override func updateLayer() { super.updateLayer() }
}

/// Section header label (big, white, heavy).
final class SectionLabel: NSTextField {
    init(_ text: String, font: NSFont = FungiTheme.title, color: NSColor = FungiTheme.ink) {
        super.init(frame: .zero)
        self.stringValue = text
        self.font = font
        self.textColor = color
        self.drawsBackground = false
        self.isBezeled = false
        self.isEditable = false
        self.isSelectable = false
    }
    required init?(coder: NSCoder) { fatalError() }
}