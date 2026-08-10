import Cocoa
import KeyboardShortcuts

// MARK: - 🔔 Chimes — user-configurable global hotkeys
//
// Backed by sindresorhus/KeyboardShortcuts (MIT), which handles Carbon hotkey
// registration, persistence in UserDefaults, conflict detection, and ships the
// recorder control used in Settings. Defaults are only a starting point — every
// one of these is rebindable from the Settings tab.

extension KeyboardShortcuts.Name {
    static let toggleBurrow  = Self("toggleBurrow",  default: .init(.f, modifiers: [.command, .option]))
    static let sporePrint    = Self("sporePrint",    default: .init(.four, modifiers: [.command, .option, .shift]))
    static let firefly       = Self("firefly",       default: .init(.e, modifiers: [.command, .option]))
    static let toggleMic     = Self("toggleMic",     default: .init(.m, modifiers: [.command, .option, .shift]))
    static let snapLeft      = Self("snapLeft",      default: .init(.leftArrow, modifiers: [.command, .option]))
    static let snapRight     = Self("snapRight",     default: .init(.rightArrow, modifiers: [.command, .option]))
    static let snapFull      = Self("snapFull",      default: .init(.upArrow, modifiers: [.command, .option]))
    static let pasteLast     = Self("pastePrevious", default: .init(.v, modifiers: [.command, .option, .shift]))
}

enum Chimes {
    /// Rows rendered in Settings: (label, shortcut name).
    static let all: [(String, KeyboardShortcuts.Name)] = [
        ("🍄  Open the Burrow", .toggleBurrow),
        ("📸  Spore Print", .sporePrint),
        ("🌟  Firefly emoji", .firefly),
        ("🎙  Mute / unmute mic", .toggleMic),
        ("⬅  Snap window left", .snapLeft),
        ("➡  Snap window right", .snapRight),
        ("⛶  Snap window full", .snapFull),
        ("📋  Copy previous clip", .pasteLast)
    ]

    /// Wire the hotkeys to their actions. Called once at launch.
    static func install(delegate: AppDelegate) {
        KeyboardShortcuts.onKeyUp(for: .toggleBurrow) { [weak delegate] in
            delegate?.togglePopover()
        }
        KeyboardShortcuts.onKeyUp(for: .sporePrint) {
            SporePrint.shared.capture()
        }
        KeyboardShortcuts.onKeyUp(for: .firefly) {
            Firefly.shared.toggle()
        }
        KeyboardShortcuts.onKeyUp(for: .toggleMic) {
            let muted = Council.toggleMute()
            Chimes.flash(muted ? "🔇 Mic muted" : "🎙 Mic live")
        }
        KeyboardShortcuts.onKeyUp(for: .snapLeft)  { Trellis.snap(.left) }
        KeyboardShortcuts.onKeyUp(for: .snapRight) { Trellis.snap(.right) }
        KeyboardShortcuts.onKeyUp(for: .snapFull)  { Trellis.snap(.full) }
        KeyboardShortcuts.onKeyUp(for: .pasteLast) { [weak delegate] in
            guard let item = delegate?.clipboard.previousClip else {
                Chimes.flash("📋 Nothing earlier in the Pantry")
                return
            }
            delegate?.clipboard.copy(item)
            Chimes.flash("📋 " + item.preview.prefix(40))
        }
    }

    /// Brief HUD for hotkeys fired while the popover is closed.
    private static var hud: NSPanel?
    static func flash(_ text: some StringProtocol) {
        hud?.orderOut(nil)
        let width: CGFloat = 260, height: CGFloat = 48
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let glass = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 14
        glass.layer?.borderWidth = 1
        glass.layer?.borderColor = FungiTheme.cap.withAlphaComponent(0.4).cgColor

        let label = NSTextField(labelWithString: String(text))
        label.font = FungiTheme.subtitle
        label.textColor = FungiTheme.ink
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 12, y: 14, width: width - 24, height: 20)
        glass.addSubview(label)
        panel.contentView = glass

        if let screen = NSScreen.main {
            let v = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: v.midX - width / 2, y: v.minY + 120))
        }
        panel.orderFrontRegardless()
        hud = panel

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            if hud === panel { panel.orderOut(nil); hud = nil }
        }
    }
}
