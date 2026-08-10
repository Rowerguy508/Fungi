import Cocoa
import Foundation
import AVFoundation
import Speech
import Vision
import CoreImage
import CoreAudio
import EventKit
import ApplicationServices
import UserNotifications
import SimplyCoreAudio

// MARK: - Shared osascript helpers

@discardableResult
func runOSA(_ script: String) -> String {
    let t = Process()
    t.launchPath = "/usr/bin/osascript"
    t.arguments = ["-e", script]
    let out = Pipe(); t.standardOutput = out; t.standardError = Pipe()
    do { try t.run() } catch { return "" }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    t.waitUntilExit()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

func runOSAWithStatus(_ script: String) -> (output: String, status: Int32) {
    let t = Process()
    t.launchPath = "/usr/bin/osascript"
    t.arguments = ["-e", script]
    let out = Pipe(); let err = Pipe()
    t.standardOutput = out; t.standardError = err
    do { try t.run() } catch { return ("\(error.localizedDescription)", -1) }
    let outData = out.fileHandleForReading.readDataToEndOfFile()
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    t.waitUntilExit()
    let o = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let e = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return (t.terminationStatus == 0 ? o : e, t.terminationStatus)
}

// MARK: - 🪜 Trellis — window snapping (Accessibility API)

enum SnapPosition { case left, right, full, topLeft, topRight, bottomLeft, bottomRight }

enum Trellis {
    static var trusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }

    /// Snap the frontmost window of the frontmost (non-Fungi) app.
    @discardableResult
    static func snap(_ pos: SnapPosition) -> Bool {
        guard trusted else { requestTrust(); return false }
        // menuBarOwningApplication survives our accessory app taking key
        guard let app = NSWorkspace.shared.menuBarOwningApplication ?? NSWorkspace.shared.frontmostApplication else { return false }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
              let winAny = winRef,
              CFGetTypeID(winAny) == AXUIElementGetTypeID() else { return false }
        // Checked above — an unguarded force cast here would crash the whole app
        // from a global hotkey when the front app exposes no focused window.
        let win = winAny as! AXUIElement
        guard let primary = NSScreen.screens.first else { return false }
        // Snap within the window's own screen. NSScreen.main follows keyboard
        // focus, which for a menu bar accessory with its popover closed is not
        // necessarily where the target window lives — using it would fling
        // windows onto the primary display on a multi-monitor setup.
        let screen = screenContaining(win, primary: primary) ?? NSScreen.main ?? primary
        let v = screen.visibleFrame
        let w = v.width, h = v.height
        let f: NSRect
        switch pos {
        case .left:        f = NSRect(x: v.minX, y: v.minY, width: w / 2, height: h)
        case .right:       f = NSRect(x: v.midX, y: v.minY, width: w / 2, height: h)
        case .full:        f = v
        case .topLeft:     f = NSRect(x: v.minX, y: v.midY, width: w / 2, height: h / 2)
        case .topRight:    f = NSRect(x: v.midX, y: v.midY, width: w / 2, height: h / 2)
        case .bottomLeft:  f = NSRect(x: v.minX, y: v.minY, width: w / 2, height: h / 2)
        case .bottomRight: f = NSRect(x: v.midX, y: v.minY, width: w / 2, height: h / 2)
        }
        // AX coordinates: origin at top-left of the primary screen, y grows downward
        var origin = CGPoint(x: f.minX, y: primary.frame.maxY - f.maxY)
        var size = CGSize(width: f.width, height: f.height)
        guard let posVal = AXValueCreate(.cgPoint, &origin),
              let sizeVal = AXValueCreate(.cgSize, &size) else { return false }
        // Set size before and after the move: a window pinned to its old
        // screen's bounds may clamp the first resize.
        AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, sizeVal)
        let posErr = AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, posVal)
        let sizeErr = AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, sizeVal)
        // Report what actually happened — a non-resizable window silently
        // refuses, and claiming "snapped" for it is a lie.
        return posErr == .success && sizeErr == .success
    }

    /// The screen the window currently sits on, by top-left corner.
    private static func screenContaining(_ win: AXUIElement, primary: NSScreen) -> NSScreen? {
        var posRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posRef) == .success,
              let posAny = posRef,
              CFGetTypeID(posAny) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(posAny as! AXValue, .cgPoint, &point) else { return nil }
        // AX y grows downward from the primary screen's top; NSScreen y grows upward.
        let flipped = NSPoint(x: point.x, y: primary.frame.maxY - point.y)
        return NSScreen.screens.first { NSPointInRect(flipped, $0.frame) }
    }
}

// MARK: - 🌟 Glow — volume (Dew) & brightness (Sunbeam)

enum Dew {
    static func outputVolume() -> Int { Int(runOSA("output volume of (get volume settings)")) ?? 50 }
    static func setOutput(_ v: Int) {
        DispatchQueue.global(qos: .userInitiated).async { runOSA("set volume output volume \(max(0, min(100, v)))") }
    }
}

enum Sunbeam {
    // NX_KEYTYPE_BRIGHTNESS_UP = 2, NX_KEYTYPE_BRIGHTNESS_DOWN = 3
    private static func postSpecialKey(_ key: Int32) {
        func post(_ down: Bool) {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00)
            let data1 = Int((Int(key) << 16) | (down ? 0xa00 : 0xb00))
            let ev = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags,
                                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                                        context: nil, subtype: 8, data1: data1, data2: -1)
            ev?.cgEvent?.post(tap: .cghidEventTap)
        }
        post(true); post(false)
    }
    static func up() { postSpecialKey(2) }
    static func down() { postSpecialKey(3) }
}

// MARK: - 🍃 Breeze — audio output picker
//
// Backed by SimplyCoreAudio (MIT) instead of raw AudioObjectGetPropertyData calls.
// It also publishes device hot-plug notifications, which is how the picker keeps
// up with AirPods and AirPlay targets appearing and vanishing.

enum Breeze {
    private static let engine = SimplyCoreAudio()
    /// Mirrors the order of the items currently in the picker.
    static var lastList: [AudioDevice] = []

    static func outputDevices() -> [AudioDevice] {
        let devices = engine.allOutputDevices.sorted { $0.name < $1.name }
        lastList = devices
        return devices
    }

    static func defaultOutput() -> AudioDevice? { engine.defaultOutputDevice }

    /// CoreAudio applies the change asynchronously, so reading `defaultOutputDevice`
    /// straight back reports failure for switches that do land a moment later —
    /// especially AirPlay. Confirm on the `defaultOutputDeviceChanged`
    /// notification instead of guessing from an immediate read.
    static func setDefaultOutput(_ device: AudioDevice, confirmed: ((Bool) -> Void)? = nil) {
        device.isDefaultOutputDevice = true
        guard let confirmed else { return }
        var observer: NSObjectProtocol?
        var settled = false
        let finish: (Bool) -> Void = { ok in
            guard !settled else { return }
            settled = true
            if let o = observer { NotificationCenter.default.removeObserver(o) }
            confirmed(ok)
        }
        observer = NotificationCenter.default.addObserver(
            forName: .defaultOutputDeviceChanged, object: nil, queue: .main
        ) { _ in finish(engine.defaultOutputDevice == device) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            finish(engine.defaultOutputDevice == device)
        }
    }

    /// Fires whenever devices are added/removed or the default output changes.
    static func observeChanges(_ handler: @escaping () -> Void) -> [NSObjectProtocol] {
        let names: [Notification.Name] = [.deviceListChanged, .defaultOutputDeviceChanged]
        return names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                handler()
            }
        }
    }
}

// MARK: - 🫂 Council — meeting detection + system-wide mic mute

enum Council {
    private static var savedMic = 75

    static func activeMeetingApp() -> String? {
        let known = ["zoom": "Zoom", "teams": "Microsoft Teams", "webex": "Webex",
                     "facetime": "FaceTime", "meet": "Google Meet", "slack": "Slack"]
        for app in NSWorkspace.shared.runningApplications {
            guard let name = app.localizedName?.lowercased() else { continue }
            for (key, label) in known where name.contains(key) { return label }
        }
        return nil
    }

    /// nil when the input volume can't be read — some interfaces report
    /// "missing value" rather than a number.
    static func micVolume() -> Int? { Int(runOSA("input volume of (get volume settings)")) }

    /// Returns true if now muted.
    ///
    /// An unreadable volume must not be treated as 0: doing so reads as
    /// "already muted" and unmutes you mid-meeting while reporting "Mic live".
    /// Unknown is treated as live, so the hotkey mutes.
    static func toggleMute() -> Bool {
        let cur = micVolume()
        if cur == nil || cur! > 0 {
            if let c = cur, c > 0 { savedMic = c }
            runOSA("set volume input volume 0")
            return true
        }
        runOSA("set volume input volume \(savedMic == 0 ? 75 : savedMic)")
        return false
    }
}

// MARK: - 🪫 Low Power Mode

enum LowPower {
    static func isOn() -> Bool {
        let t = Process()
        t.launchPath = "/usr/bin/pmset"
        t.arguments = ["-g"]
        let p = Pipe(); t.standardOutput = p; t.standardError = Pipe()
        do { try t.run() } catch { return false }
        let out = String(data: p.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        t.waitUntilExit()
        for line in out.components(separatedBy: "\n") where line.contains("lowpowermode") {
            return line.trimmingCharacters(in: .whitespaces).hasSuffix("1")
        }
        return false
    }

    static func set(_ on: Bool, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            runOSA("do shell script \"pmset -a lowpowermode \(on ? 1 : 0)\" with administrator privileges")
            let ok = isOn() == on
            DispatchQueue.main.async { completion(ok) }
        }
    }
}

// MARK: - 📸 Spore Print — screenshot capture + markup editor

final class MarkupView: NSView {
    let image: NSImage
    private var strokes: [NSBezierPath] = []
    private var current: NSBezierPath?
    var color = NSColor.systemRed

    init(image: NSImage, frame: NSRect) {
        self.image = image
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        image.draw(in: bounds)
        color.setStroke()
        for p in strokes { p.stroke() }
        current?.stroke()
    }
    override func mouseDown(with event: NSEvent) {
        let p = NSBezierPath()
        p.lineWidth = 3; p.lineCapStyle = .round; p.lineJoinStyle = .round
        p.move(to: convert(event.locationInWindow, from: nil))
        current = p
    }
    override func mouseDragged(with event: NSEvent) {
        current?.line(to: convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        if let c = current { strokes.append(c) }
        current = nil
        needsDisplay = true
    }
    func clear() { strokes.removeAll(); needsDisplay = true }

    /// Composite the marks onto the *original* capture rather than snapshotting
    /// this view — the view is scaled down to fit on screen, so rendering it
    /// would throw away most of the screenshot's resolution.
    func rendered() -> NSImage? {
        let full = image.size
        guard full.width > 0, full.height > 0, bounds.width > 0, bounds.height > 0 else { return nil }
        let scaleX = full.width / bounds.width
        let scaleY = full.height / bounds.height

        let out = NSImage(size: full)
        out.lockFocus()
        defer { out.unlockFocus() }
        image.draw(in: NSRect(origin: .zero, size: full))

        guard let ctx = NSGraphicsContext.current else { return nil }
        ctx.saveGraphicsState()
        let xform = NSAffineTransform()
        xform.scaleX(by: scaleX, yBy: scaleY)
        xform.concat()
        color.setStroke()
        for p in strokes {
            let scaled = p.copy() as! NSBezierPath
            // Keep the on-screen stroke weight after the upscale.
            scaled.lineWidth = p.lineWidth / max(scaleX, scaleY)
            scaled.stroke()
        }
        ctx.restoreGraphicsState()
        return out
    }
}

final class SporePrint: NSObject {
    static let shared = SporePrint()
    private var window: NSWindow?
    private var markup: MarkupView?
    var onSaved: ((URL) -> Void)?

    /// Interactive region capture (Cmd-Shift-4 style), then open the markup editor.
    func capture() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sporeprint-\(UUID().uuidString).png")
        let t = Process()
        t.launchPath = "/usr/sbin/screencapture"
        t.arguments = ["-i", tmp.path]
        t.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let img = NSImage(contentsOf: tmp) else { return }
                self?.openEditor(img)
            }
        }
        try? t.run()
    }

    func openEditor(_ image: NSImage) {
        window?.close()
        let maxSize = NSSize(width: 880, height: 560)
        var s = image.size
        let scale = min(1, min(maxSize.width / max(s.width, 1), maxSize.height / max(s.height, 1)))
        s = NSSize(width: s.width * scale, height: s.height * scale)
        let barH: CGFloat = 44
        let winW = max(s.width, 400)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: winW, height: s.height + barH),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "🍄 Spore Print"
        w.isReleasedWhenClosed = false
        w.level = .floating

        let root = NSView(frame: NSRect(x: 0, y: 0, width: winW, height: s.height + barH))
        root.wantsLayer = true
        root.layer?.backgroundColor = FungiTheme.canopy.cgColor

        let mv = MarkupView(image: image, frame: NSRect(x: (winW - s.width) / 2, y: barH, width: s.width, height: s.height))
        root.addSubview(mv)
        markup = mv

        func toolButton(_ title: String, x: CGFloat, width: CGFloat, action: Selector) {
            let b = ShroomButton(title: title, color: FungiTheme.gill)
            b.target = self; b.action = action
            b.frame = NSRect(x: x, y: 8, width: width, height: 28)
            root.addSubview(b)
        }
        toolButton("📋 Copy", x: 10, width: 90, action: #selector(copyEdited))
        toolButton("🧺 Save to Basket", x: 108, width: 150, action: #selector(saveEdited))
        toolButton("🧽 Clear marks", x: 266, width: 124, action: #selector(clearMarks))

        w.contentView = root
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }

    @objc private func copyEdited() {
        guard let img = markup?.rendered() else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([img])
    }
    @objc private func saveEdited() {
        guard let img = markup?.rendered(), let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let dest = Storage.shared.basketDir
            .appendingPathComponent("Spore Print \(df.string(from: Date())).png")
        try? png.write(to: dest)
        onSaved?(dest)
    }
    @objc private func clearMarks() { markup?.clear() }
}

// MARK: - 🌟 Firefly — emoji picker panel

final class Firefly: NSObject {
    static let shared = Firefly()
    private var panel: NSPanel?
    private var status: NSTextField?

    private let emoji = [
        "😀","😃","😄","😁","😅","😂","🤣","🥲","😊","🙂",
        "😉","😍","🥰","😘","😜","🤪","🤨","😎","🥸","🤩",
        "🥳","😏","😤","😠","😡","🥺","😢","😭","😱","😴",
        "🤯","🫠","🫡","🫶","👍","👎","👌","✌️","🤞","🤘",
        "👏","🙌","🙏","🤝","💪","👀","🧠","🔥","✨","⭐️",
        "⚡️","💥","💯","❤️","🧡","💛","💚","💙","💜","🖤",
        "💔","❣️","💕","🎉","🎊","🎂","🍕","🍔","🌮","🍣",
        "☕️","🍺","🥂","🍄","🌱","🌈","☀️","🌙","☁️","❄️",
        "🚀","✈️","🚗","🏠","💻","📱","💡","🔑","📌","✅",
        "❌","❓","❗️","💬","🐛","🦉","🐦","🦊","🐌","🐝"
    ]

    func toggle() {
        if let p = panel, p.isVisible { p.orderOut(nil); return }
        if panel == nil { build() }
        panel?.center()
        panel?.orderFrontRegardless()
    }

    private func build() {
        let cols = 10
        let cell: CGFloat = 32
        let pad: CGFloat = 12
        let rows = Int(ceil(Double(emoji.count) / Double(cols)))
        let w = CGFloat(cols) * cell + pad * 2
        let h = CGFloat(rows) * cell + pad * 2 + 26
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                        styleMask: [.titled, .closable, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.title = "🌟 Firefly"
        p.isReleasedWhenClosed = false
        p.level = .floating

        let root = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        root.material = .hudWindow
        root.blendingMode = .behindWindow
        root.state = .active

        for (i, e) in emoji.enumerated() {
            let col = i % cols, row = i / cols
            let b = NSButton(title: e, target: self, action: #selector(pick(_:)))
            b.isBordered = false
            b.font = NSFont.systemFont(ofSize: 20)
            b.frame = NSRect(x: pad + CGFloat(col) * cell,
                             y: h - pad - CGFloat(row + 1) * cell,
                             width: cell, height: cell)
            root.addSubview(b)
        }

        let s = NSTextField(labelWithString: "Click an emoji to copy it")
        s.font = FungiTheme.mono
        s.textColor = FungiTheme.fog
        s.alignment = .center
        s.frame = NSRect(x: 0, y: 6, width: w, height: 16)
        root.addSubview(s)
        status = s

        p.contentView = root
        panel = p
    }

    @objc private func pick(_ sender: NSButton) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(sender.title, forType: .string)
        status?.stringValue = "\(sender.title) copied — paste anywhere"
    }
}

// MARK: - 🪵 Hollow — terminal in the burrow

final class Hollow {
    static let shared = Hollow()
    private(set) var running = false

    func run(_ command: String, completion: @escaping (String) -> Void) {
        guard !running else { completion("(previous command still running)"); return }
        running = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let t = Process()
            t.launchPath = "/bin/zsh"
            t.arguments = ["-lc", command]
            let p = Pipe()
            t.standardOutput = p
            t.standardError = p
            do { try t.run() } catch {
                DispatchQueue.main.async { self?.running = false; completion("error: \(error.localizedDescription)") }
                return
            }
            let data = p.fileHandleForReading.readDataToEndOfFile()
            t.waitUntilExit()
            var out = String(data: data, encoding: .utf8) ?? ""
            if out.count > 20000 { out = String(out.prefix(20000)) + "\n…(truncated)" }
            if out.isEmpty { out = "(exit \(t.terminationStatus))" }
            DispatchQueue.main.async { self?.running = false; completion(out) }
        }
    }
}

// MARK: - 🎙 Echo — voice recording + transcription (Speech framework)

final class EchoRecorder: NSObject {
    static let shared = EchoRecorder()
    private var recorder: AVAudioRecorder?
    private var recognizer: SFSpeechRecognizer?
    private(set) var isRecording = false
    private(set) var lastFile: URL?
    var onTranscript: ((String) -> Void)?

    var echoesDir: URL {
        let d = (Storage.shared.icloudDir ?? Storage.shared.supportDir)
            .appendingPathComponent("Echoes", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func begin(status: @escaping (String, Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard granted else {
                    status("Mic access denied — System Settings › Privacy › Microphone", false)
                    return
                }
                self?.startRecording(status: status)
            }
        }
    }

    private func startRecording(status: (String, Bool) -> Void) {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let url = echoesDir.appendingPathComponent("Echo \(df.string(from: Date())).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        recorder = try? AVAudioRecorder(url: url, settings: settings)
        if recorder?.record() == true {
            lastFile = url
            isRecording = true
            status("⏺ Recording… tap Stop when done", true)
        } else {
            status("Couldn't start the recorder", false)
        }
    }

    func stop() {
        recorder?.stop()
        recorder = nil
        isRecording = false
        if let f = lastFile { transcribe(f) }
    }

    func transcribe(_ url: URL) {
        SFSpeechRecognizer.requestAuthorization { [weak self] auth in
            guard let self else { return }
            guard auth == .authorized else {
                DispatchQueue.main.async { self.onTranscript?("(speech recognition not authorized — System Settings › Privacy)") }
                return
            }
            guard let rec = SFSpeechRecognizer(), rec.isAvailable else {
                DispatchQueue.main.async { self.onTranscript?("(speech recognizer unavailable)") }
                return
            }
            self.recognizer = rec
            let req = SFSpeechURLRecognitionRequest(url: url)
            rec.recognitionTask(with: req) { result, error in
                if let r = result, r.isFinal {
                    let text = r.bestTranscription.formattedString
                    let txtFile = url.deletingPathExtension().appendingPathExtension("txt")
                    try? text.write(to: txtFile, atomically: true, encoding: .utf8)
                    DispatchQueue.main.async { self.onTranscript?(text.isEmpty ? "(no speech detected)" : text) }
                } else if error != nil {
                    DispatchQueue.main.async { self.onTranscript?("(transcription failed)") }
                }
            }
        }
    }
}

// MARK: - 📖 Almanac — natural-language events & reminders (EventKit)

enum Almanac {
    static let store = EKEventStore()

    static func plant(_ input: String, asReminder: Bool, completion: @escaping (String) -> Void) {
        let requestAccess: (@escaping (Bool) -> Void) -> Void = { done in
            if asReminder {
                if #available(macOS 14.0, *) { store.requestFullAccessToReminders { g, _ in done(g) } }
                else { store.requestAccess(to: .reminder) { g, _ in done(g) } }
            } else {
                if #available(macOS 14.0, *) { store.requestFullAccessToEvents { g, _ in done(g) } }
                else { store.requestAccess(to: .event) { g, _ in done(g) } }
            }
        }
        requestAccess { granted in
            DispatchQueue.main.async {
                guard granted else {
                    completion("Access denied — System Settings › Privacy › \(asReminder ? "Reminders" : "Calendars")")
                    return
                }
                var title = input
                var date: Date? = nil
                if let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
                   let m = det.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
                   let d = m.date {
                    date = d
                    if let r = Range(m.range, in: input) {
                        title = input.replacingCharacters(in: r, with: "")
                    }
                }
                title = title.trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
                for suffix in [" at", " on", " At", " On"] where title.hasSuffix(suffix) {
                    title = String(title.dropLast(suffix.count))
                }
                if title.isEmpty { title = asReminder ? "Reminder" : "Event" }
                let f = DateFormatter(); f.dateFormat = "EEE MMM d, HH:mm"
                do {
                    if asReminder {
                        let r = EKReminder(eventStore: store)
                        r.title = title
                        r.calendar = store.defaultCalendarForNewReminders()
                        if let d = date {
                            r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: d)
                            r.addAlarm(EKAlarm(absoluteDate: d))
                        }
                        try store.save(r, commit: true)
                        completion("🌱 Reminder planted: \(title)" + (date.map { " — \(f.string(from: $0))" } ?? ""))
                    } else {
                        guard let d = date else {
                            completion("Couldn't find a date — try “Lunch with Sam tomorrow 12:30”")
                            return
                        }
                        let e = EKEvent(eventStore: store)
                        e.title = title
                        e.startDate = d
                        e.endDate = d.addingTimeInterval(3600)
                        e.calendar = store.defaultCalendarForNewEvents
                        try store.save(e, span: .thisEvent, commit: true)
                        completion("🌱 Event planted: \(title) — \(f.string(from: d))")
                    }
                } catch {
                    completion("Planting failed: \(error.localizedDescription)")
                }
            }
        }
    }
}

// MARK: - 🐦 Songbird — line-synced live lyrics (Music app + lrclib.net)

final class Songbird {
    static let shared = Songbird()
    struct LyricLine { let time: TimeInterval; let text: String }

    private(set) var active = false
    private var timer: Timer?
    private var lines: [LyricLine] = []
    private var currentTrackKey = ""
    /// Tracks we've already looked up and found nothing for, so the label can
    /// say so instead of sitting on "searching…" for the rest of the song.
    private var unavailable: Set<String> = []
    var onUpdate: ((String) -> Void)?

    private let pollScript = """
    tell application "System Events" to set musicRunning to (name of processes) contains "Music"
    if musicRunning then
        tell application "Music"
            if player state is playing then
                return (name of current track) & "|~|" & (artist of current track) & "|~|" & (player position as string)
            end if
        end tell
    end if
    return ""
    """

    func start() {
        guard !active else { return }
        active = true
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }

    func stop() {
        active = false
        timer?.invalidate(); timer = nil
        currentTrackKey = ""
        lines = []
        onUpdate?("")
    }

    private func poll() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let out = runOSA(self.pollScript)
            DispatchQueue.main.async { self.handle(out) }
        }
    }

    private func handle(_ out: String) {
        guard active else { return }
        guard !out.isEmpty else { onUpdate?("🐦 Nothing playing in Music"); return }
        let parts = out.components(separatedBy: "|~|")
        guard parts.count >= 3,
              let pos = Double(parts[2].replacingOccurrences(of: ",", with: ".")) else {
            onUpdate?("🐦 …")
            return
        }
        let key = parts[0] + "—" + parts[1]
        if key != currentTrackKey {
            currentTrackKey = key
            lines = []
            fetch(track: parts[0], artist: parts[1])
        }
        guard !lines.isEmpty else {
            onUpdate?(unavailable.contains(key)
                ? "🐦 \(parts[0]) — no synced lyrics found"
                : "🐦 \(parts[0]) — searching for lyrics…")
            return
        }
        let idx = lines.lastIndex(where: { $0.time <= pos }) ?? 0
        let cur = lines[idx].text.isEmpty ? "♪" : lines[idx].text
        let next = idx + 1 < lines.count ? lines[idx + 1].text : ""
        onUpdate?("🎶 \(cur)\n\(next)")
    }

    private func fetch(track: String, artist: String) {
        var comps = URLComponents(string: "https://lrclib.net/api/get")!
        comps.queryItems = [
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "track_name", value: track)
        ]
        guard let url = comps.url else { return }
        let expectKey = currentTrackKey
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self else { return }
            let parsed: [LyricLine] = {
                guard let data,
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let synced = obj["syncedLyrics"] as? String, !synced.isEmpty else { return [] }
                return Songbird.parseLRC(synced)
            }()
            DispatchQueue.main.async {
                guard self.currentTrackKey == expectKey else { return }
                // Record the miss too — a 404 or an unsynced-only entry must not
                // leave the label stuck on "searching…" for the whole track.
                if parsed.isEmpty { self.unavailable.insert(expectKey) } else { self.lines = parsed }
            }
        }.resume()
    }

    static func parseLRC(_ s: String) -> [LyricLine] {
        guard let regex = try? NSRegularExpression(pattern: "^\\[(\\d+):(\\d+(?:\\.\\d+)?)\\]\\s*(.*)$") else { return [] }
        var out: [LyricLine] = []
        for line in s.components(separatedBy: "\n") {
            let ns = line as NSString
            guard let m = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            let min = Double(ns.substring(with: m.range(at: 1))) ?? 0
            let sec = Double(ns.substring(with: m.range(at: 2))) ?? 0
            out.append(LyricLine(time: min * 60 + sec, text: ns.substring(with: m.range(at: 3))))
        }
        return out.sorted { $0.time < $1.time }
    }
}

// MARK: - 📮 Quick Post — instant replies (iMessage + WhatsApp)

enum QuickPost {
    private static func escaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func sendIMessage(to handle: String, text: String) -> (ok: Bool, error: String) {
        let script = """
        tell application "Messages"
            set targetService to 1st account whose service type = iMessage
            set targetBuddy to participant "\(escaped(handle))" of targetService
            send "\(escaped(text))" to targetBuddy
        end tell
        """
        let (out, status) = runOSAWithStatus(script)
        return (status == 0, out)
    }

    /// Opens WhatsApp (app if installed, else web) with a pre-filled draft.
    static func openWhatsApp(phone: String, text: String) {
        let digits = phone.filter { "0123456789".contains($0) }
        let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let appURL = URL(string: "whatsapp://send?phone=\(digits)&text=\(encoded)"),
           NSWorkspace.shared.open(appURL) {
            return
        }
        if let webURL = URL(string: "https://wa.me/\(digits)?text=\(encoded)") {
            NSWorkspace.shared.open(webURL)
        }
    }
}

// MARK: - 🫥 Peel — AI background removal (Vision, macOS 14+)

enum Peel {
    static func removeBackground(from url: URL, completion: @escaping (URL?, String) -> Void) {
        guard #available(macOS 14.0, *) else {
            completion(nil, "Peel needs macOS 14 (Sonoma) or later")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            guard let ci = CIImage(contentsOf: url) else {
                DispatchQueue.main.async { completion(nil, "Couldn't read that image") }
                return
            }
            let request = VNGenerateForegroundInstanceMaskRequest()
            let handler = VNImageRequestHandler(ciImage: ci, options: [:])
            do {
                try handler.perform([request])
                guard let obs = request.results?.first else {
                    DispatchQueue.main.async { completion(nil, "No subject found in the image") }
                    return
                }
                let buffer = try obs.generateMaskedImage(ofInstances: obs.allInstances,
                                                         from: handler,
                                                         croppedToInstancesExtent: false)
                let out = CIImage(cvPixelBuffer: buffer)
                let dest = Storage.shared.basketDir
                    .appendingPathComponent(url.deletingPathExtension().lastPathComponent + " (peeled).png")
                let ctx = CIContext()
                try ctx.writePNGRepresentation(of: out, to: dest, format: .RGBA8,
                                               colorSpace: CGColorSpaceCreateDeviceRGB())
                DispatchQueue.main.async { completion(dest, "🫥 Peeled → Basket: \(dest.lastPathComponent)") }
            } catch {
                DispatchQueue.main.async { completion(nil, "Peel failed: \(error.localizedDescription)") }
            }
        }
    }
}

// MARK: - 🦗 Cricket spore — mechanical keyboard sounds

final class CricketSpore: Spore {
    let id = "cricket"
    let name = "Cricket (key sounds)"
    let icon = "🦗"
    var enabled = UserDefaults.standard.bool(forKey: "spore.cricket") { didSet { UserDefaults.standard.set(enabled, forKey: "spore.cricket") } }
    private(set) var statusText = "Chirps on every keypress"
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private let chirps = ["Tink", "Pop"]
    private var i = 0

    func start() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in self?.chirp() }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in self?.chirp(); return e }
        statusText = "Chirping 🎶 (needs Input Monitoring permission)"
    }
    func stop() {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        statusText = "Quiet"
    }
    private func chirp() {
        i = (i + 1) % chirps.count
        NSSound(named: NSSound.Name(chirps[i]))?.play()
    }
}

// MARK: - 🦉 Familiar spore — AI coding agent tracking (Claude / Codex / aider)

final class FamiliarSpore: Spore {
    let id = "familiar"
    let name = "Familiar (AI agents)"
    let icon = "🦉"
    var enabled = UserDefaults.standard.bool(forKey: "spore.familiar") { didSet { UserDefaults.standard.set(enabled, forKey: "spore.familiar") } }
    private(set) var statusText = "Watching for claude/codex/aider"
    private var timer: Timer?
    private let agents = ["claude", "codex", "aider", "cursor-agent"]

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }
    func stop() { timer?.invalidate(); timer = nil; statusText = "Familiar asleep" }

    private func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            var found: [String] = []
            for a in self.agents {
                let t = Process()
                t.launchPath = "/usr/bin/pgrep"
                t.arguments = ["-x", a]
                let p = Pipe(); t.standardOutput = p; t.standardError = Pipe()
                do { try t.run() } catch { continue }
                let out = String(data: p.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                t.waitUntilExit()
                guard let pid = out.components(separatedBy: "\n").first, !pid.isEmpty else { continue }
                let ps = Process()
                ps.launchPath = "/bin/ps"
                ps.arguments = ["-o", "%cpu=", "-p", pid]
                let pp = Pipe(); ps.standardOutput = pp; ps.standardError = Pipe()
                try? ps.run()
                let cpu = String(data: pp.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
                ps.waitUntilExit()
                let working = (Double(cpu) ?? 0) > 5
                found.append("\(a) \(working ? "⚡︎ working" : "idle")")
            }
            let text = found.isEmpty ? "No agents running" : found.joined(separator: " · ")
            DispatchQueue.main.async { self.statusText = text }
        }
    }
}
