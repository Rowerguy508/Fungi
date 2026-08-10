import Cocoa
import Foundation
import Combine
import AppKit
import UserNotifications
import ServiceManagement
import AVFoundation
import MediaPlayer
import Security
import IOKit.ps
import EventKit
import Network
import Swifter
import KeyboardShortcuts

// MARK: - Models

struct ClipboardItem: Identifiable, Codable, Equatable {
    let id: UUID
    let timestamp: Date
    let text: String?
    let imagePath: String?
    let filePaths: [String]?

    var preview: String {
        if let t = text { return t.prefix(120).description }
        if let p = imagePath { return "🖼 " + (p as NSString).lastPathComponent }
        if let paths = filePaths, let first = paths.first {
            return "📎 " + ((first as NSString).lastPathComponent) + (paths.count > 1 ? " +\(paths.count - 1)" : "")
        }
        return "(empty)"
    }
}

struct TimerEntry: Identifiable, Codable {
    let id: UUID
    var label: String
    var fireDate: Date
    var paused: Bool
    var remaining: TimeInterval
}

// MARK: - Storage (iCloud-first with local fallback)

final class Storage {
    static let shared = Storage()
    let supportDir: URL
    let icloudDir: URL?
    /// Always present. iCloud when available, Application Support otherwise —
    /// the Basket backs the Basket tab, Spore Cloud, Spore Print and Peel, and
    /// none of them should vanish just because iCloud Drive is off.
    let basketDir: URL
    let clipsFile: URL
    let timersFile: URL
    let imagesDir: URL

    private init() {
        let fm = FileManager.default
        let base = try! fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        supportDir = base.appendingPathComponent("Fungi", isDirectory: true)
        try? fm.createDirectory(at: supportDir, withIntermediateDirectories: true)

        // iCloud Drive location
        var cloud: URL? = nil
        if let cloudBase = fm.url(forUbiquityContainerIdentifier: nil) {
            cloud = cloudBase.appendingPathComponent("Documents/Fungi", isDirectory: true)
            try? fm.createDirectory(at: cloud!, withIntermediateDirectories: true)
        } else {
            // Fallback: direct iCloud Drive folder path
            let home = FileManager.default.homeDirectoryForCurrentUser
            let alt = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Fungi", isDirectory: true)
            if fm.fileExists(atPath: alt.path) || (try? fm.createDirectory(at: alt, withIntermediateDirectories: true)) != nil {
                cloud = alt
            }
        }
        icloudDir = cloud
        basketDir = (cloud ?? supportDir).appendingPathComponent("Basket", isDirectory: true)
        try? fm.createDirectory(at: basketDir, withIntermediateDirectories: true)

        imagesDir = (icloudDir ?? supportDir).appendingPathComponent("clipImages", isDirectory: true)
        try? fm.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        clipsFile = (icloudDir ?? supportDir).appendingPathComponent("clips.json")
        timersFile = (icloudDir ?? supportDir).appendingPathComponent("timers.json")
    }

    var usingICloud: Bool { icloudDir != nil }

    func loadClips() -> [ClipboardItem] {
        guard let data = try? Data(contentsOf: clipsFile),
              let arr = try? JSONDecoder().decode([ClipboardItem].self, from: data) else {
            return []
        }
        return arr
    }
    func saveClips(_ items: [ClipboardItem]) {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: clipsFile, options: .atomic)
        }
    }
    func loadTimers() -> [TimerEntry] {
        guard let data = try? Data(contentsOf: timersFile),
              let arr = try? JSONDecoder().decode([TimerEntry].self, from: data) else { return [] }
        return arr
    }
    func saveTimers(_ items: [TimerEntry]) {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: timersFile, options: .atomic)
        }
    }
    func imageURL(for name: String) -> URL { imagesDir.appendingPathComponent(name) }

    /// Files dropped into the tray (live listing of Basket dir)
    func basketFiles() -> [URL] {
        let d = basketDir
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: d,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles)) ?? []
        return urls.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
    }
    func addToBasket(from src: URL) -> URL? {
        let d = basketDir
        let dest = d.appendingPathComponent(src.lastPathComponent)
        var final = dest
        var i = 1
        while FileManager.default.fileExists(atPath: final.path) {
            let name = (dest.deletingPathExtension().lastPathComponent) + " \(i)." + dest.pathExtension
            final = d.appendingPathComponent(name)
            i += 1
        }
        do {
            try FileManager.default.copyItem(at: src, to: final)
            return final
        } catch { return nil }
    }
}

// MARK: - Clipboard Manager

final class ClipboardManager: ObservableObject {
    @Published private(set) var items: [ClipboardItem] = []
    @Published var search: String = ""
    private var lastChangeCount: Int = NSPasteboard.general.changeCount
    private var timer: Timer?
    let maxItems = 200

    func start() {
        items = Storage.shared.loadClips()
        timer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func poll() {
        let pb = NSPasteboard.general
        if pb.changeCount == lastChangeCount { return }
        lastChangeCount = pb.changeCount

        var text: String? = nil
        var imagePath: String? = nil
        var filePaths: [String]? = nil

        if let s = pb.string(forType: .string), !s.isEmpty {
            text = s
        } else if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            filePaths = urls.map { $0.path }
        } else if let img = NSImage(pasteboard: pb) {
            if let tiff = img.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                let name = UUID().uuidString + ".png"
                let url = Storage.shared.imageURL(for: name)
                try? png.write(to: url)
                imagePath = name
            }
        }

        if text == nil && imagePath == nil && (filePaths == nil || filePaths?.isEmpty == true) { return }
        let item = ClipboardItem(id: UUID(), timestamp: Date(), text: text, imagePath: imagePath, filePaths: filePaths)
        items.insert(item, at: 0)
        if items.count > maxItems { items.removeLast(items.count - maxItems) }
        Storage.shared.saveClips(items)
    }

    var filtered: [ClipboardItem] {
        if search.isEmpty { return items }
        return items.filter { ($0.text ?? "").localizedCaseInsensitiveContains(search) }
    }

    func copy(_ item: ClipboardItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if let t = item.text {
            pb.setString(t, forType: .string)
        } else if let p = item.imagePath {
            if let img = NSImage(contentsOf: Storage.shared.imageURL(for: p)) {
                pb.writeObjects([img])
            }
        } else if let paths = item.filePaths {
            pb.writeObjects(paths.map { URL(fileURLWithPath: $0) } as [NSURL])
        }
        // clearContents() bumps changeCount, so without this the next poll
        // re-records what we just wrote and the Pantry fills with duplicates
        // every time a clip is recopied.
        lastChangeCount = pb.changeCount
    }

    /// The most recent clip that isn't what's already on the pasteboard.
    /// `items.first` is the current pasteboard content, so recopying it does
    /// nothing — this is what the "paste previous clip" hotkey wants.
    var previousClip: ClipboardItem? { items[safe: 1] }

    func clear() {
        items.removeAll()
        Storage.shared.saveClips(items)
    }
}

// MARK: - Media Controller (AppleScript-based to avoid MediaRemote private API)

enum MediaCommand: String { case play, pause, next, previous, toggle }

final class MediaController {
    static func send(_ cmd: MediaCommand) {
        let script: String
        switch cmd {
        case .play, .pause, .toggle:
            script = "tell application \"System Events\" to keystroke (ASCII character 16) using {command down}"
        case .next:
            script = "tell application \"System Events\" to key code 124 using {command down, option down}"
        case .previous:
            script = "tell application \"System Events\" to key code 123 using {command down, option down}"
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.launchPath = "/usr/bin/osascript"
            task.arguments = ["-e", script]
            try? task.run()
        }
    }
}

// MARK: - Timer Manager

final class TimerManager: ObservableObject {
    @Published private(set) var timers: [TimerEntry] = []
    @Published var label: String = ""
    @Published var minutes: Int = 25

    func start() { timers = Storage.shared.loadTimers() }
    func add() {
        let entry = TimerEntry(id: UUID(), label: label.isEmpty ? "Timer" : label,
                              fireDate: Date().addingTimeInterval(TimeInterval(minutes * 60)),
                              paused: false, remaining: TimeInterval(minutes * 60))
        timers.append(entry)
        Storage.shared.saveTimers(timers)
        label = ""
        requestNotifPerm()
    }
    func cancel(_ id: UUID) {
        timers.removeAll { $0.id == id }
        Storage.shared.saveTimers(timers)
    }
    func tick() {
        let now = Date()
        var changed = false
        for t in timers where !t.paused {
            let remaining = t.fireDate.timeIntervalSince(now)
            if remaining <= 0 {
                notify(label: t.label)
                if let idx = timers.firstIndex(where: { $0.id == t.id }) {
                    timers.remove(at: idx); changed = true
                }
            }
        }
        if changed { Storage.shared.saveTimers(timers) }
    }
    private func notify(label: String) {
        let content = UNMutableNotificationContent()
        content.title = "Timer done"
        content.body = label
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
    private func requestNotifPerm() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}

// MARK: - Drag & Drop Target View

final class BasketView: NSView {
    var onDrop: ((URL) -> Void)?
    var label: String = "Drop files here" {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1.5
        layer?.borderColor = NSColor(calibratedRed: 0.3, green: 0.6, blue: 1.0, alpha: 0.6).cgColor
        layer?.backgroundColor = NSColor(calibratedRed: 0.15, green: 0.25, blue: 0.45, alpha: 0.5).cgColor
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor(white: 0.8, alpha: 1),
            .font: NSFont.systemFont(ofSize: 13, weight: .medium)
        ]
        let size = (label as NSString).size(withAttributes: attrs)
        (label as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        layer?.borderColor = NSColor(calibratedRed: 0.5, green: 0.9, blue: 1.0, alpha: 1).cgColor
        layer?.backgroundColor = NSColor(calibratedRed: 0.2, green: 0.4, blue: 0.6, alpha: 0.7).cgColor
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        layer?.borderColor = NSColor(calibratedRed: 0.3, green: 0.6, blue: 1.0, alpha: 0.6).cgColor
        layer?.backgroundColor = NSColor(calibratedRed: 0.15, green: 0.25, blue: 0.45, alpha: 0.5).cgColor
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        layer?.borderColor = NSColor(calibratedRed: 0.3, green: 0.6, blue: 1.0, alpha: 0.6).cgColor
        layer?.backgroundColor = NSColor(calibratedRed: 0.15, green: 0.25, blue: 0.45, alpha: 0.5).cgColor
        if let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], let first = urls.first {
            onDrop?(first)
            return true
        }
        return false
    }
}

// MARK: - Floating Pill (Dynamic Island style)

final class PillController: NSObject {
    private var panel: NSPanel!
    private var timeLabel: NSTextField!
    private var clipLabel: NSTextField!
    private var onToggle: (() -> Void)?

    init(onToggle: @escaping () -> Void) {
        self.onToggle = onToggle
        super.init()
        build()
    }

    private func build() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 40),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let container = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 240, height: 40))
        container.material = .hudWindow
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 20
        container.layer?.borderWidth = 1
        container.layer?.borderColor = FungiTheme.cap.withAlphaComponent(0.4).cgColor
        panel.contentView = container

        // 🍄 emoji badge
        let badge = NSTextField(labelWithString: "🍄")
        badge.font = NSFont.systemFont(ofSize: 18)
        badge.frame = NSRect(x: 14, y: 11, width: 26, height: 20)
        container.addSubview(badge)

        timeLabel = NSTextField(labelWithString: "")
        timeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        timeLabel.textColor = FungiTheme.ink
        timeLabel.frame = NSRect(x: 42, y: 11, width: 80, height: 18)
        container.addSubview(timeLabel)

        clipLabel = NSTextField(labelWithString: "📋 0")
        clipLabel.font = FungiTheme.mono
        clipLabel.textColor = FungiTheme.gill
        clipLabel.frame = NSRect(x: 124, y: 11, width: 56, height: 18)
        container.addSubview(clipLabel)

        let btn = NSButton(title: "⏯", target: self, action: #selector(playPause))
        btn.isBordered = false
        btn.font = NSFont.systemFont(ofSize: 14)
        btn.contentTintColor = FungiTheme.moss
        btn.frame = NSRect(x: 178, y: 8, width: 28, height: 22)
        container.addSubview(btn)

        let open = NSButton(title: "▦", target: self, action: #selector(openFungi))
        open.isBordered = false
        open.font = NSFont.systemFont(ofSize: 14)
        open.contentTintColor = FungiTheme.gill
        open.frame = NSRect(x: 206, y: 8, width: 28, height: 22)
        container.addSubview(open)
    }

    func show() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let x = visible.midX - 110
        let y = visible.maxY + 2
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFrontRegardless()
        startClock()
    }

    func hide() { panel.orderOut(nil) }
    var isVisible: Bool { panel.isVisible }

    private func startClock() {
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.timeLabel.stringValue = Self.timeNow()
        }
        timeLabel.stringValue = Self.timeNow()
    }
    private static func timeNow() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: Date())
    }
    func setClipCount(_ n: Int) { clipLabel.stringValue = "📋 \(n)" }

    @objc private func playPause() { MediaController.send(.toggle) }
    @objc private func openFungi() { onToggle?() }
}

// MARK: - Spores (extension system)

protocol Spore: AnyObject {
    var id: String { get }
    var name: String { get }
    var icon: String { get }
    var enabled: Bool { get set }
    var statusText: String { get }
    func start()
    func stop()
}

final class PomodoroSpore: Spore {
    let id = "pomodoro"
    let name = "Pomodoro"
    let icon = "🍅"
    var enabled = UserDefaults.standard.bool(forKey: "spore.pomodoro") { didSet { UserDefaults.standard.set(enabled, forKey: "spore.pomodoro") } }
    private(set) var statusText = "25 min focus / 5 min break"
    private var timer: Timer?
    private var isFocus = true
    private var remaining: TimeInterval = 25 * 60

    func start() {
        isFocus = true
        remaining = 25 * 60
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        notify("Focus session started", "25 minutes. Go!")
    }
    func stop() {
        timer?.invalidate(); timer = nil
        statusText = "Paused"
    }
    private func tick() {
        remaining -= 1
        let m = Int(remaining) / 60, s = Int(remaining) % 60
        statusText = "\(isFocus ? "Focus" : "Break")  \(m):\(String(format: "%02d", s))"
        if remaining <= 0 {
            isFocus.toggle()
            remaining = isFocus ? 25 * 60 : 5 * 60
            notify(isFocus ? "Break over — focus!" : "Focus done — take a break", isFocus ? "25 minutes. Go!" : "5 minutes. Stretch!")
        }
    }
    private func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

final class BatterySpore: Spore {
    let id = "battery"
    let name = "Battery monitor"
    let icon = "🔋"
    var enabled = UserDefaults.standard.bool(forKey: "spore.battery") { didSet { UserDefaults.standard.set(enabled, forKey: "spore.battery") } }
    private(set) var statusText = "Monitoring battery"
    private var timer: Timer?
    private var lastAlerted = false

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.check() }
        check()
    }
    func stop() { timer?.invalidate(); timer = nil; statusText = "Monitoring off" }

    private func check() {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        guard !sources.isEmpty else {
            statusText = "No battery (desktop?)"; return
        }
        for src in sources {
            if let desc = IOPSGetPowerSourceDescription(info, src)?.takeUnretainedValue() as? [String: Any],
               let current = desc[kIOPSCurrentCapacityKey] as? Int,
               let max = desc[kIOPSMaxCapacityKey] as? Int {
                let pct = Int(Double(current) / Double(max) * 100)
                statusText = "\(pct)%"
                if pct <= 20 && !lastAlerted {
                    let c = UNMutableNotificationContent()
                    c.title = "Battery low"; c.body = "\(pct)% remaining — plug in!"; c.sound = .default
                    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
                    lastAlerted = true
                } else if pct > 25 { lastAlerted = false }
                return
            }
        }
    }
}

final class WeatherSpore: Spore {
    let id = "weather"
    let name = "Weather"
    let icon = "🌤"
    var enabled = UserDefaults.standard.bool(forKey: "spore.weather") { didSet { UserDefaults.standard.set(enabled, forKey: "spore.weather") } }
    private(set) var statusText = "Fetching weather…"

    func start() { refresh() }
    func stop() { statusText = "Weather off" }

    func refresh() {
        statusText = "Fetching…"
        let url = URL(string: "https://wttr.in/?format=%t+%C&lang=en")!
        let task = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            if let data, let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                DispatchQueue.main.async { self?.statusText = s }
            } else {
                DispatchQueue.main.async { self?.statusText = "Weather unavailable" }
            }
        }
        task.resume()
    }
}

final class SporeManager {
    static let shared = SporeManager()
    let spores: [Spore] = [
        // Productivity
        PomodoroSpore(), TruffleSpore(), BambooSpore(), MorelSpore(), CloverSpore(),
        // System
        BatterySpore(), SystemStatsSpore(), NetworkSpore(), StalkSpore(), LichenSpore(),
        MothSpore(), CapstoneSpore(), PollenSpore(), WeatherSpore(), CalendarSpore(), FernSpore(),
        // Activity
        MyceliumSpore(), PinSpore(), BeeSpore(), ConiferSpore(),
        // Fun
        MapleSpore(), FoxSpore(), WarblerSpore(), QuillSpore(),
        CricketSpore(), FamiliarSpore(),
        // Shell
        FrontmostURLSpore(), RootSpore(), SporeworkSpore(), BloomSpore(), HuskSpore(),
        LeafSpore()
    ]
    var refreshUI: (() -> Void)?
    private init() {
        for d in spores where d.enabled { d.start() }
    }
    func toggle(_ d: Spore) {
        d.enabled.toggle()
        if d.enabled { d.start() } else { d.stop() }
        refreshUI?()
    }
}

// MARK: - Calendar spore (EventKit)

final class CalendarSpore: Spore {
    let id = "calendar"
    let name = "Calendar"
    let icon = "📅"
    var enabled = UserDefaults.standard.bool(forKey: "spore.calendar") { didSet { UserDefaults.standard.set(enabled, forKey: "spore.calendar") } }
    private(set) var statusText = "Next event: —"
    private let store = EKEventStore()
    private var timer: Timer?

    func start() {
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents { [weak self] granted, _ in
                guard let self else { return }
                if granted { self.refresh() }
                else { self.statusText = "Calendar access denied — check System Settings" }
            }
        } else {
            store.requestAccess(to: .event) { [weak self] granted, _ in
                guard let self else { return }
                if granted { self.refresh() } else { self.statusText = "Calendar access denied" }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
    }
    func stop() { timer?.invalidate(); timer = nil; statusText = "Calendar off" }

    private func refresh() {
        let start = Date()
        let end = start.addingTimeInterval(7 * 86400)
        let pred = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: pred).filter { $0.startDate > start }.sorted { $0.startDate < $1.startDate }
        if let next = events.first {
            let f = DateFormatter(); f.dateFormat = "EEE HH:mm"
            statusText = "\(next.title ?? "Untitled") @ \(f.string(from: next.startDate))"
        } else {
            statusText = "No upcoming events"
        }
    }
}

// MARK: - Frontmost URL spore (Safari/Chrome)

final class FrontmostURLSpore: Spore {
    let id = "frontmost-url"
    let name = "Frontmost URL"
    let icon = "🌐"
    var enabled = UserDefaults.standard.bool(forKey: "spore.frontmost-url") { didSet { UserDefaults.standard.set(enabled, forKey: "spore.frontmost-url") } }
    private(set) var statusText = "URL: —"
    private var timer: Timer?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }
    func stop() { timer?.invalidate(); timer = nil; statusText = "URL monitor off" }

    private func refresh() {
        let script = """
        tell application "System Events"
            set frontApp to name of first application process whose frontmost is true
        end tell
        if frontApp is "Safari" then
            tell application "Safari" to return URL of front document
        else if frontApp is "Google Chrome" or frontApp is "Chromium" then
            tell application frontApp to return URL of active tab of front window
        else
            return frontApp
        end if
        """
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", script]
        let pipe = Pipe(); task.standardOutput = pipe; task.standardError = Pipe()
        do { try task.run() } catch { statusText = "URL: error"; return }
        // Wait with timeout to avoid hangs when Accessibility perms are denied
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            task.waitUntilExit()
            sem.signal()
        }
        if sem.wait(timeout: .now() + .seconds(2)) == .timedOut {
            task.terminate()
            statusText = "URL: timeout (grant Automation in System Settings)"; return
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if out.hasPrefix("http") {
            let short = out.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
            statusText = "URL: \(short)"
        } else if !out.isEmpty {
            statusText = "App: \(out)"
        }
    }
}

// MARK: - System stats spore

final class SystemStatsSpore: Spore {
    let id = "system-stats"
    let name = "System stats"
    let icon = "💻"
    var enabled = UserDefaults.standard.bool(forKey: "spore.system-stats") { didSet { UserDefaults.standard.set(enabled, forKey: "spore.system-stats") } }
    private(set) var statusText = "CPU — | RAM —"
    private var timer: Timer?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }
    func stop() { timer?.invalidate(); timer = nil; statusText = "Stats off" }

    private func refresh() {
        // CPU: load average normalized by core count
        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        var ncpu: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("hw.ncpu", &ncpu, &size, nil, 0)
        let cpuPct = ncpu > 0 ? min(100, Int(load[0] / Double(ncpu) * 100)) : 0

        // RAM via host_statistics64
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            let total = Double(stats.active_count + stats.inactive_count + stats.wire_count + stats.free_count) * Double(pageSize)
            let used = Double(stats.active_count + stats.inactive_count + stats.wire_count) * Double(pageSize)
            let ramPct = total > 0 ? Int(used / total * 100) : 0
            statusText = "CPU \(cpuPct)% | RAM \(ramPct)%"
        } else {
            statusText = "CPU \(cpuPct)%"
        }
    }
}

// MARK: - Network spore (SSID + latency)

final class NetworkSpore: Spore {
    let id = "network"
    let name = "Network"
    let icon = "📶"
    var enabled = UserDefaults.standard.bool(forKey: "spore.network") { didSet { UserDefaults.standard.set(enabled, forKey: "spore.network") } }
    private(set) var statusText = "WiFi —"
    private var timer: Timer?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }
    func stop() { timer?.invalidate(); timer = nil; statusText = "Network off" }

    private func refresh() {
        // SSID via networksetup
        let ssidTask = Process()
        ssidTask.launchPath = "/usr/sbin/networksetup"
        ssidTask.arguments = ["-getairportnetwork", "en0"]
        let pipe = Pipe(); ssidTask.standardOutput = pipe; ssidTask.standardError = Pipe()
        try? ssidTask.run()
        let ssidData = pipe.fileHandleForReading.readDataToEndOfFile()
        let ssidOut = String(data: ssidData, encoding: .utf8) ?? ""
        let ssid = ssidOut.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "—"

        // Latency: ping 1.1.1.1 once
        let ping = Process()
        ping.launchPath = "/sbin/ping"
        ping.arguments = ["-c", "1", "-t", "2", "1.1.1.1"]
        let p2 = Pipe(); ping.standardOutput = p2; ping.standardError = Pipe()
        try? ping.run()
        let pingData = p2.fileHandleForReading.readDataToEndOfFile()
        let pingOut = String(data: pingData, encoding: .utf8) ?? ""
        if let range = pingOut.range(of: "time="), let end = pingOut[range.upperBound...].firstIndex(of: " ") {
            let ms = pingOut[range.upperBound..<end]
            statusText = "\(ssid) · \(ms)ms"
        } else {
            statusText = "\(ssid) · offline"
        }
    }
}

// MARK: - Spore Cloud (LAN share links + iCloud share sheet)

final class SporeCloud {
    static let shared = SporeCloud()
    static let port: in_port_t = 8420

    var isRunning = false
    private let server = HttpServer()
    private var statusChanged: (() -> Void)?

    func start(statusChanged: @escaping () -> Void) {
        self.statusChanged = statusChanged
        // Browsable index so a phone on the same WiFi can see the whole basket.
        server["/"] = { [weak self] _ in .ok(.html(self?.indexHTML() ?? "<h1>🍄 Fungi</h1>")) }
        server["/spores/:path"] = { [weak self] request in
            guard let self, let raw = request.params.first?.value else { return .notFound }
            return self.serveBasketFile(raw)
        }

        do {
            try server.start(Self.port, forceIPv4: true)
            isRunning = true
        } catch {
            isRunning = false
        }
        statusChanged()
    }

    func stop() {
        server.stop()
        isRunning = false
        statusChanged?()
    }

    /// Serve one file out of the Basket.
    ///
    /// Deliberately not Swifter's `shareFilesFromDirectory`: that concatenates
    /// the request path straight onto the directory with no containment check,
    /// and `HttpRouter` percent-decodes the token before handing it over — so
    /// `GET /spores/..%2F..%2F..%2Fetc%2Fpasswd` walks out of the Basket and
    /// serves anything the user can read to anyone on the LAN.
    ///
    /// The Basket is flat, so collapsing to the last path component removes any
    /// traversal outright; the containment check below backstops that in case
    /// the layout ever gains subdirectories.
    private func serveBasketFile(_ requested: String) -> HttpResponse {
        let basket = Storage.shared.basketDir

        let name = (requested as NSString).lastPathComponent
        // Reject empty, "."/"..", and dotfiles.
        guard !name.isEmpty, !name.hasPrefix(".") else { return .notFound }

        let fileURL = basket.appendingPathComponent(name)
        let basketPath = basket.resolvingSymlinksInPath().standardizedFileURL.path
        let filePath = fileURL.resolvingSymlinksInPath().standardizedFileURL.path
        guard filePath.hasPrefix(basketPath + "/") else { return .notFound }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: filePath, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let file = try? filePath.openForReading() else { return .notFound }

        var headers = ["Content-Type": name.mimeType()]
        if let attrs = try? FileManager.default.attributesOfItem(atPath: filePath),
           let size = attrs[.size] as? UInt64 {
            headers["Content-Length"] = String(size)
        }
        return .raw(200, "OK", headers) { writer in
            try? writer.write(file)
            file.close()
        }
    }

    private func indexHTML() -> String {
        let files = Storage.shared.basketFiles()
        let fmt = ByteCountFormatter(); fmt.countStyle = .file
        let rows = files.map { url -> String in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let name = url.lastPathComponent
            let href = "/spores/" + (name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name)
            return "<li><a href=\"\(href)\">\(name.htmlEscaped)</a><span>\(fmt.string(fromByteCount: Int64(size)))</span></li>"
        }.joined(separator: "\n")
        let body = files.isEmpty ? "<p class=\"empty\">The basket is empty.</p>" : "<ul>\(rows)</ul>"
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>🍄 Spore Cloud</title><style>
        body{font:16px -apple-system,system-ui,sans-serif;background:#0f1219;color:#eee;margin:0;padding:24px}
        h1{font-size:22px;margin:0 0 4px}p.sub{color:#8b8f98;margin:0 0 20px;font-size:14px}
        ul{list-style:none;padding:0;margin:0}
        li{display:flex;justify-content:space-between;gap:12px;align-items:center;
           background:#1a1e26;border-radius:12px;padding:12px 16px;margin-bottom:8px}
        a{color:#e8a37a;text-decoration:none;word-break:break-all}
        span{color:#8b8f98;font-size:13px;white-space:nowrap}
        p.empty{color:#8b8f98}
        </style></head><body>
        <h1>🍄 Spore Cloud</h1><p class="sub">\(files.count) file\(files.count == 1 ? "" : "s") in the basket</p>
        \(body)</body></html>
        """
    }

    /// A share link for a given filename served over LAN. Returns nil if not running.
    func link(for name: String) -> String? {
        guard isRunning, let ip = localIP() else { return nil }
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        return "http://\(ip):\(Self.port)/spores/\(encoded)"
    }

    /// The browsable basket index, for sharing the whole basket at once.
    func indexLink() -> String? {
        guard isRunning, let ip = localIP() else { return nil }
        return "http://\(ip):\(Self.port)/"
    }

    private func localIP() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        var ptr = ifaddr
        while ptr != nil {
            let interface = ptr!.pointee
            let family = interface.ifa_addr.pointee.sa_family
            if family == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" || name == "en1" {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                    address = String(cString: host)
                }
            }
            ptr = interface.ifa_next
        }
        freeifaddrs(ifaddr)
        return address
    }
}

// MARK: - Nightcap Widget Overlay (idle-triggered, like Fungi nightcap)

final class NightcapController {
    static let shared = NightcapController()
    var enabled = UserDefaults.standard.bool(forKey: "nightcap.enabled") { didSet { UserDefaults.standard.set(enabled, forKey: "nightcap.enabled") } }
    var idleMinutes = UserDefaults.standard.integer(forKey: "nightcap.idleMinutes") == 0 ? 5 : UserDefaults.standard.integer(forKey: "nightcap.idleMinutes")
    private var panel: NSPanel?
    private var idleTimer: Timer?
    private var clockTimer: Timer?
    private var shown = false

    func startMonitoring() {
        idleTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.checkIdle()
        }
    }

    private func checkIdle() {
        guard enabled else { if shown { hide() }; return }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved)
        if idle >= Double(idleMinutes * 60), !shown {
            show()
        } else if idle < 10, shown {
            hide()
        }
    }

    func show() {
        guard let screen = NSScreen.main, !shown else { return }
        let frame = screen.frame
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .screenSaver
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let v = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 0.6).cgColor
        p.contentView = v

        // Big clock
        let time = NSTextField(labelWithString: "")
        time.font = NSFont.monospacedDigitSystemFont(ofSize: 96, weight: .thin)
        time.textColor = .white
        time.alignment = .center
        time.frame = NSRect(x: 0, y: frame.height / 2 - 60, width: frame.width, height: 110)
        v.addSubview(time)

        // Date
        let date = NSTextField(labelWithString: "")
        date.font = NSFont.systemFont(ofSize: 22, weight: .medium)
        date.textColor = NSColor(white: 0.85, alpha: 1)
        date.alignment = .center
        date.frame = NSRect(x: 0, y: frame.height / 2 - 90, width: frame.width, height: 30)
        v.addSubview(date)

        // Widgets row (battery, weather, calendar, clips)
        let widgets = NSStackView()
        widgets.orientation = .horizontal
        widgets.distribution = .fillEqually
        widgets.spacing = 16
        widgets.frame = NSRect(x: 40, y: 80, width: frame.width - 80, height: 90)
        v.addSubview(widgets)

        let batteryLbl = widgetLabel("🔋 --")
        let weatherLbl = widgetLabel("🌤 --")
        let calLbl = widgetLabel("📅 --")
        let clipsLbl = widgetLabel("📋 0")
        for w in [batteryLbl, weatherLbl, calLbl, clipsLbl] { widgets.addArrangedSubview(w) }

        p.orderFrontRegardless()
        panel = p
        shown = true

        let tf = DateFormatter(); tf.dateFormat = "HH:mm"
        let df = DateFormatter(); df.dateFormat = "EEEE, MMMM d"
        time.stringValue = tf.string(from: Date())
        date.stringValue = df.string(from: Date())

        clockTimer?.invalidate()
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.shown else { return }
            time.stringValue = tf.string(from: Date())
            date.stringValue = df.string(from: Date())
            let spores = SporeManager.shared.spores
            for d in spores {
                if d.id == "battery" && d.enabled { batteryLbl.stringValue = "🔋 \(d.statusText)" }
                if d.id == "weather" && d.enabled { weatherLbl.stringValue = "🌤 \(d.statusText)" }
                if d.id == "calendar" && d.enabled { calLbl.stringValue = "📅 \(d.statusText)" }
            }
            clipsLbl.stringValue = "📋 \(self.clipCount)"
        }
    }

    var clipCount = 0
    var isShown: Bool { shown }

    func hide() {
        clockTimer?.invalidate(); clockTimer = nil
        panel?.orderOut(nil)
        panel = nil
        shown = false
    }
}

private func widgetLabel(_ text: String) -> NSTextField {
    let l = NSTextField(labelWithString: text)
    l.font = NSFont.systemFont(ofSize: 15, weight: .medium)
    l.textColor = .white
    l.alignment = .center
    l.lineBreakMode = .byTruncatingTail
    return l
}

// MARK: - App Delegate (Menu Bar)

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    let statusBar = NSStatusBar.system
    let popover = NSPopover()
    let popoverVC = PopoverViewController()
    let clipboard = ClipboardManager()
    let timerManager = TimerManager()
    var tickTimer: Timer?
    var pill: PillController?
    var showPill = UserDefaults.standard.bool(forKey: "showPill")

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = statusBar.statusItem(withLength: NSStatusItem.variableLength)
        if let img = NSImage(systemSymbolName: "mushroom.fill", accessibilityDescription: "Fungi") {
            img.isTemplate = true
            statusItem.button?.image = img
        } else {
            statusItem.button?.title = "🍄"
        }
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 540, height: 660)
        popover.contentViewController = popoverVC
        popoverVC.clipboard = clipboard
        popoverVC.timerManager = timerManager
        clipboard.start()
        timerManager.start()
        _ = SporeManager.shared
        Chimes.install(delegate: self)
        NightcapController.shared.startMonitoring()
        SporeCloud.shared.start { [weak self] in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.popoverVC.refreshCloudStateSafe()
            }
        }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.timerManager.tick()
        }
        if showPill { togglePill() }
        // Refresh spore status every 5s while the fairy ring is open
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self = self, self.popoverVC.currentTab == .fairyring else { return }
            self.popoverVC.sporeTable.reloadData()
        }
    }

    func togglePill() {
        if let p = pill {
            p.hide(); pill = nil; showPill = false
        } else {
            let p = PillController(onToggle: { [weak self] in self?.togglePopover() })
            p.show(); pill = p; showPill = true
        }
        UserDefaults.standard.set(showPill, forKey: "showPill")
    }

    @objc func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.becomeKey()
        }
    }

    // Note the spelling: ...Closed, not ...Closure. Misspelled, this silently
    // matches nothing on NSApplicationDelegate and never runs, leaving the
    // menu bar app free to quit when its last window goes away.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

// MARK: - Popover View

final class PopoverViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    weak var clipboard: ClipboardManager?
    weak var timerManager: TimerManager?

    // Fungi vocabulary
    enum Tab: Int, CaseIterable {
        case burrow, pantry, basket, timers, media, grove, post, almanac, hollow, echo, fairyring, settings
        var title: String {
            switch self {
            case .burrow: return "Burrow"
            case .pantry: return "Pantry"
            case .basket: return "Basket"
            case .timers: return "Timers"
            case .media: return "Media"
            case .grove: return "Grove"
            case .post: return "Post"
            case .almanac: return "Almanac"
            case .hollow: return "Hollow"
            case .echo: return "Echo"
            case .fairyring: return "Fairy Ring"
            case .settings: return "Settings"
            }
        }
        var icon: String {
            switch self {
            case .burrow: return "🍄"
            case .pantry: return "📋"
            case .basket: return "🧺"
            case .timers: return "⏱"
            case .media: return "🎵"
            case .grove: return "🌳"
            case .post: return "📮"
            case .almanac: return "📖"
            case .hollow: return "🪵"
            case .echo: return "🎙"
            case .fairyring: return "🪄"
            case .settings: return "⚙"
            }
        }
    }
    var currentTab: Tab = .burrow
    var tabButtons: [NSButton] = []

    // Subviews
    let header = GlassCard(frame: .zero)
    let titleLabel = SectionLabel("The Burrow", font: FungiTheme.display)
    let subtitleLabel = SectionLabel("A fungi takes root in your Mac", font: FungiTheme.subtitle, color: FungiTheme.fog)
    let icloudBadge = NSTextField(labelWithString: "")

    let searchField = NSTextField()
    let clipTable = NSTableView()
    let fileTable = NSTableView()
    let timerList = NSTableView()
    let sporeTable = NSTableView() // legacy — Fairy Ring now uses sporeGrid
    var sporeGrid: NSView!
    var sporeGridCells: [SporeCell] = []
    var sporeGridFlair: SporeCell?

    var basketView: BasketView!
    var mediaRow: NSStackView!
    var timerAdd: NSStackView!
    var timerLabelField: NSTextField!
    var timerMinutesField: NSTextField!
    var launchAtLogin: NSButton!
    var pillToggle: NSButton!
    var shareButton: NSButton!
    var cloudLinkBtn: NSButton!
    var basketIndexBtn: NSButton!
    var cloudStatusLabel: NSTextField!
    var cloudToggleButton: NSButton!
    var nightcapToggle: NSButton!
    var nightcapHint: NSTextField!
    var sporeHint: NSTextField!
    var statusLabel: NSTextField!

    // Grove build-out panes + controls (built in GroveUI.swift)
    var grovePane: NSView!
    var postPane: NSView!
    var almanacPane: NSView!
    var hollowPane: NSView!
    var echoPane: NSView!
    var groveVolume: NSSlider!
    var groveOutputs: NSPopUpButton!
    var groveMicBtn: NSButton!
    var groveMeetingLabel: NSTextField!
    var grovePowerToggle: NSButton!
    var groveHint: NSTextField!
    var postHandleField: NSTextField!
    var postMessageField: NSTextField!
    var postStatus: NSTextField!
    var almanacField: NSTextField!
    var almanacReminderToggle: NSButton!
    var almanacStatus: NSTextField!
    var hollowField: NSTextField!
    var hollowOutput: NSTextView!
    var echoButton: NSButton!
    var echoStatus: NSTextField!
    var echoOutput: NSTextView!
    var lyricsToggle: NSButton!
    var lyricsLabel: NSTextField!
    var mediaTitleLabel: NSTextField!
    var mediaHintLabel: NSTextField!
    var breezeObservers: [NSObjectProtocol] = []
    var shortcutRows: [NSView] = []

    // Status bar
    let footer = GlassCard(frame: .zero)
    var footerLabel: NSTextField!
    var footerBtn: NSButton!

    override func loadView() {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 540, height: 660))
        v.wantsLayer = true
        v.layer?.backgroundColor = FungiTheme.canopy.cgColor
        self.view = v

        // --- Header ---
        header.frame = NSRect(x: 0, y: 580, width: 540, height: 80)
        v.addSubview(header)

        let titleStack = NSStackView()
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 2
        titleStack.frame = NSRect(x: 20, y: 14, width: 380, height: 52)
        titleStack.addArrangedSubview(titleLabel)
        titleStack.addArrangedSubview(subtitleLabel)
        header.addSubview(titleStack)

        icloudBadge.font = FungiTheme.mono
        icloudBadge.textColor = FungiTheme.moss
        icloudBadge.backgroundColor = FungiTheme.canopy.withAlphaComponent(0.5)
        icloudBadge.drawsBackground = true
        icloudBadge.isBezeled = false
        icloudBadge.isEditable = false
        icloudBadge.alignment = .center
        icloudBadge.wantsLayer = true
        icloudBadge.layer?.cornerRadius = 8
        icloudBadge.frame = NSRect(x: 380, y: 28, width: 140, height: 24)
        header.addSubview(icloudBadge)
        refreshICloudBadge()

        // --- Sidebar nav ---
        // Solid backdrop behind the sidebar so the tab labels are readable
        // regardless of the wallpaper. Goes underneath the nav stack.
        let sidebarBackdrop = NSView(frame: NSRect(x: 12, y: 130, width: 130, height: 440))
        sidebarBackdrop.wantsLayer = true
        sidebarBackdrop.layer?.backgroundColor = FungiTheme.humus.cgColor
        sidebarBackdrop.layer?.cornerRadius = 10
        v.addSubview(sidebarBackdrop)

        let nav = NSStackView()
        nav.orientation = .vertical
        nav.alignment = .leading
        nav.spacing = 4
        nav.frame = NSRect(x: 12, y: 130, width: 130, height: 440)
        for tab in Tab.allCases {
            let b = NSButton(title: "\(tab.icon)  \(tab.title)", target: self, action: #selector(switchTab(_:)))
            b.tag = tab.rawValue
            b.bezelStyle = .inline
            b.isBordered = false
            b.font = FungiTheme.tab
            b.contentTintColor = FungiTheme.fog
            b.alignment = .left
            b.wantsLayer = true
            b.layer?.cornerRadius = 8
            b.frame = NSRect(x: 0, y: 0, width: 130, height: 30)
            tabButtons.append(b)
            nav.addArrangedSubview(b)
        }
        v.addSubview(nav)
        applyTabStyles()

        // --- Content card (everything except footer lives in here) ---
        // Fully opaque rounded rectangle on the humus palette — no glass.
        // The earlier NSVisualEffectView / .hudWindow tint left the card
        // looking see-through against some wallpapers, so we drop the
        // material effect entirely. The NSView itself is the opaque surface.
        let content = NSView(frame: NSRect(x: 152, y: 130, width: 376, height: 440))
        content.wantsLayer = true
        content.layer?.backgroundColor = FungiTheme.humus.cgColor
        content.layer?.cornerRadius = 12
        content.layer?.borderWidth = 1
        content.layer?.borderColor = FungiTheme.cap.withAlphaComponent(0.35).cgColor
        v.addSubview(content)

        // Each tab's content is added to `content` then hidden/shown
        buildBurrow(in: content)
        buildPantry(in: content)
        buildBasket(in: content)
        buildTimers(in: content)
        buildMedia(in: content)
        buildGrove(in: content)
        buildPost(in: content)
        buildAlmanac(in: content)
        buildHollow(in: content)
        buildEcho(in: content)
        buildFairyRing(in: content)
        buildSettings(in: content)

        // --- Footer ---
        footer.frame = NSRect(x: 12, y: 12, width: 516, height: 36)
        v.addSubview(footer)
        footerLabel = NSTextField(labelWithString: "Ready.")
        footerLabel.font = FungiTheme.mono
        footerLabel.textColor = FungiTheme.fog
        footerLabel.frame = NSRect(x: 14, y: 10, width: 380, height: 18)
        footer.addSubview(footerLabel)
        statusLabel = footerLabel
        footerBtn = NSButton(title: "🍄 Open Fungi", target: self, action: #selector(openApp))
        footerBtn.bezelStyle = .inline
        footerBtn.isBordered = false
        footerBtn.font = FungiTheme.subtitle
        footerBtn.contentTintColor = FungiTheme.gill
        footerBtn.frame = NSRect(x: 400, y: 6, width: 110, height: 24)
        footer.addSubview(footerBtn)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        switchTab(tabButtons[currentTab.rawValue])
    }

    func refreshICloudBadge() {
        if Storage.shared.usingICloud {
            icloudBadge.stringValue = " ☁ iCloud "
            icloudBadge.textColor = FungiTheme.moss
        } else {
            icloudBadge.stringValue = " ☁ Local "
            icloudBadge.textColor = FungiTheme.cap
        }
    }

    func applyTabStyles() {
        for (i, b) in tabButtons.enumerated() {
            let active = (i == currentTab.rawValue)
            b.contentTintColor = active ? FungiTheme.ink : FungiTheme.fog
            // Active tab gets a clearly opaque cap-tone fill so it pops;
            // inactive tabs get a subtle 6% white wash so each row is still
            // discernible as a clickable target, even on busy wallpapers.
            b.layer?.backgroundColor = (active
                ? FungiTheme.cap.withAlphaComponent(0.55)
                : NSColor(calibratedWhite: 1.0, alpha: 0.06)).cgColor
            b.layer?.borderWidth = active ? 1 : 0
            b.layer?.borderColor = FungiTheme.spore.withAlphaComponent(active ? 0.85 : 0).cgColor
        }
    }

    @objc func switchTab(_ sender: NSButton) {
        guard let tab = Tab(rawValue: sender.tag) else { return }
        currentTab = tab
        applyTabStyles()
        titleLabel.stringValue = tab.title
        switch tab {
        case .burrow: subtitleLabel.stringValue = "A fungi takes root in your Mac"
        case .pantry: subtitleLabel.stringValue = "Every copy, kept and searchable"
        case .basket: subtitleLabel.stringValue = "Toss files into your basket (iCloud sync)"
        case .timers: subtitleLabel.stringValue = "Ticking along until ready"
        case .media: subtitleLabel.stringValue = "Music at the cap of your Mac"
        case .grove: subtitleLabel.stringValue = "Handy tools under the canopy"
        case .post: subtitleLabel.stringValue = "Quick replies, carried by moths"
        case .almanac: subtitleLabel.stringValue = "Plain words become plans"
        case .hollow: subtitleLabel.stringValue = "A terminal in the hollow log"
        case .echo: subtitleLabel.stringValue = "Speak — the forest writes it down"
        case .fairyring: subtitleLabel.stringValue = "Pick your toadstools"
        case .settings: subtitleLabel.stringValue = "Tune your fungi"
        }
        for v in [searchField, clipTable, fileTable, timerList, basketView,
                  mediaRow, timerAdd, sporeTable, sporeGrid, sporeHint, cloudStatusLabel,
                  cloudToggleButton, nightcapToggle, nightcapHint,
                  launchAtLogin, pillToggle, shareButton, cloudLinkBtn, basketIndexBtn] {
            v?.isHidden = true
        }
        for v in [grovePane, postPane, almanacPane, hollowPane, echoPane,
                  lyricsToggle, lyricsLabel, mediaTitleLabel, mediaHintLabel] as [NSView?] {
            v?.isHidden = true
        }
        for v in shortcutRows { v.isHidden = true }
        switch tab {
        case .burrow:
            buildBurrowContents()
        case .pantry:
            searchField.isHidden = false
            clipTable.isHidden = false
            clipTable.reloadData()
        case .basket:
            basketView.isHidden = false
            fileTable.isHidden = false
            shareButton.isHidden = false
            cloudLinkBtn.isHidden = false
            basketIndexBtn.isHidden = false
            fileTable.reloadData()
        case .timers:
            timerList.isHidden = false
            timerAdd.isHidden = false
            timerList.reloadData()
        case .media:
            mediaRow.isHidden = false
            mediaTitleLabel.isHidden = false
            mediaHintLabel.isHidden = false
            lyricsToggle.isHidden = false
            lyricsLabel.isHidden = false
            lyricsToggle.state = Songbird.shared.active ? .on : .off
        case .grove:
            grovePane.isHidden = false
            refreshGrove()
        case .post:
            postPane.isHidden = false
        case .almanac:
            almanacPane.isHidden = false
        case .hollow:
            hollowPane.isHidden = false
        case .echo:
            echoPane.isHidden = false
        case .fairyring:
            sporeTable.isHidden = true // legacy table kept for state but hidden
            sporeHint.isHidden = false
            sporeGrid?.isHidden = false
            refreshFairyRing()
        case .settings:
            launchAtLogin.isHidden = false
            pillToggle.isHidden = false
            cloudStatusLabel.isHidden = false
            cloudToggleButton.isHidden = false
            nightcapToggle.isHidden = false
            nightcapHint.isHidden = false
            for v in shortcutRows { v.isHidden = false }
            refreshSettings()
        }
    }

    func refreshSettings() {
        refreshICloudBadge()
        refreshCloudState()
        launchAtLogin.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        pillToggle.state = (UserDefaults.standard.bool(forKey: "showPill")) ? .on : .off
        cloudToggleButton.state = (SporeCloud.shared.isRunning ? .on : .off)
        nightcapToggle.state = (NightcapController.shared.enabled ? .on : .off)
    }

    @objc func openApp() { NSApp.activate(ignoringOtherApps: true) }

    // MARK: - Tab content builders

    func buildBurrow(in parent: NSView) {
        // Card shown when Burrow tab is active.
        // The content card already has a humus-tone opaque backdrop (set up
        // in loadView), so Burrow only needs to frame its hero/tagline/blurb
        // — no second NSVisualEffectView on top, which would re-introduce
        // transparency against busy wallpapers.
        let card = NSView(frame: NSRect(x: 14, y: 16, width: 368, height: 408))
        card.wantsLayer = true
        card.layer?.cornerRadius = FungiTheme.cardRadius
        card.identifier = NSUserInterfaceItemIdentifier("burrowCard")
        parent.addSubview(card)

        let hero = NSTextField(labelWithString: "🍄")
        hero.font = NSFont.systemFont(ofSize: 80)
        hero.alignment = .center
        hero.frame = NSRect(x: 0, y: 240, width: 368, height: 100)
        card.addSubview(hero)

        let tagline = NSTextField(labelWithString: "Fungi takes root in your Mac.")
        tagline.font = FungiTheme.title
        tagline.alignment = .center
        tagline.textColor = FungiTheme.ink
        tagline.frame = NSRect(x: 0, y: 200, width: 368, height: 22)
        card.addSubview(tagline)

        let blurb = NSTextField(labelWithString: "Drop a file into the Basket. Open a toadstool from the Fairy Ring.\nLet the Nightcap drift over your screen when idle.\n\nPress 🍄 in your menu bar to come back here.")
        blurb.font = FungiTheme.body
        blurb.alignment = .center
        blurb.textColor = FungiTheme.fog
        blurb.maximumNumberOfLines = 0
        blurb.frame = NSRect(x: 28, y: 80, width: 312, height: 100)
        card.addSubview(blurb)

        let status = NSTextField(labelWithString: "")
        status.font = FungiTheme.mono
        status.alignment = .center
        status.textColor = FungiTheme.moss
        status.frame = NSRect(x: 28, y: 28, width: 312, height: 36)
        status.maximumNumberOfLines = 0
        status.identifier = NSUserInterfaceItemIdentifier("burrowStatus")
        card.addSubview(status)
    }

    func buildBurrowContents() {
        // Refresh the status line each time the Burrow is shown
        guard let card = view.subviews.flatMap({ $0.subviews }).first(where: { $0.identifier?.rawValue == "burrowCard" }) else { return }
        let status = card.subviews.first(where: { $0.identifier?.rawValue == "burrowStatus" }) as? NSTextField
        let enabled = SporeManager.shared.spores.filter(\.enabled).count
        let total = SporeManager.shared.spores.count
        let timerCount = timerManager?.timers.count ?? 0
        let basketCount = Storage.shared.basketFiles().count
        let cloud = SporeCloud.shared.isRunning ? "on" : "off"
        let nightcap = NightcapController.shared.enabled ? "on" : "off"
        status?.stringValue = "🍄 Toadstools active: \(enabled)/\(total)\n🧺 Basket: \(basketCount) files · ⏱ \(timerCount) timers · ☁ Cloud: \(cloud) · 🌙 Nightcap: \(nightcap)"
    }

    func buildPantry(in parent: NSView) {
        searchField.frame = NSRect(x: 14, y: 396, width: 368, height: 28)
        searchField.placeholderString = "Search the pantry…"
        searchField.bezelStyle = .roundedBezel
        searchField.font = FungiTheme.body
        searchField.delegate = self
        parent.addSubview(searchField)
        let clipCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c"))
        clipCol.width = 370
        clipTable.addTableColumn(clipCol)
        clipTable.headerView = nil
        clipTable.dataSource = self
        clipTable.delegate = self
        clipTable.backgroundColor = FungiTheme.humus
        clipTable.frame = NSRect(x: 14, y: 16, width: 370, height: 372)
        parent.addSubview(clipTable)
    }

    func buildBasket(in parent: NSView) {
        basketView = BasketView(frame: NSRect(x: 14, y: 376, width: 368, height: 50))
        basketView.label = "Drop files → basket (iCloud)"
        basketView.onDrop = { [weak self] url in
            _ = Storage.shared.addToBasket(from: url)
            self?.fileTable.reloadData()
            self?.footerLabel.stringValue = "Tossed into the basket: \(url.lastPathComponent)"
        }
        parent.addSubview(basketView)

        shareButton = ShroomButton(title: "Share", icon: "↗", color: FungiTheme.spore)
        shareButton.target = self; shareButton.action = #selector(shareFile)
        shareButton.frame = NSRect(x: 14, y: 336, width: 100, height: 32)
        parent.addSubview(shareButton)

        cloudLinkBtn = ShroomButton(title: "Copy link", icon: "🔗", color: FungiTheme.moss)
        cloudLinkBtn.target = self; cloudLinkBtn.action = #selector(copyShareLink)
        cloudLinkBtn.frame = NSRect(x: 118, y: 336, width: 126, height: 32)
        parent.addSubview(cloudLinkBtn)

        basketIndexBtn = ShroomButton(title: "Browse", icon: "🌐", color: FungiTheme.gill)
        basketIndexBtn.target = self; basketIndexBtn.action = #selector(openBasketIndex)
        basketIndexBtn.frame = NSRect(x: 250, y: 336, width: 118, height: 32)
        parent.addSubview(basketIndexBtn)

        let fileCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("f"))
        fileCol.width = 370
        fileTable.addTableColumn(fileCol)
        fileTable.headerView = nil
        fileTable.dataSource = self
        fileTable.delegate = self
        fileTable.backgroundColor = FungiTheme.humus
        fileTable.frame = NSRect(x: 14, y: 16, width: 370, height: 312)
        parent.addSubview(fileTable)
    }

    func buildTimers(in parent: NSView) {
        let timerCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("t"))
        timerCol.width = 370
        timerList.addTableColumn(timerCol)
        timerList.headerView = nil
        timerList.dataSource = self
        timerList.delegate = self
        timerList.backgroundColor = FungiTheme.humus
        timerList.frame = NSRect(x: 14, y: 96, width: 370, height: 296)
        parent.addSubview(timerList)

        let timerAddLocal = NSStackView()
        timerAddLocal.orientation = .horizontal
        timerAddLocal.spacing = 6
        timerAddLocal.frame = NSRect(x: 14, y: 40, width: 368, height: 40)
        timerLabelField = NSTextField(string: "")
        timerLabelField.placeholderString = "Label"
        timerLabelField.bezelStyle = .roundedBezel
        timerLabelField.frame = NSRect(x: 0, y: 8, width: 160, height: 24)
        timerMinutesField = NSTextField(string: "25")
        timerMinutesField.bezelStyle = .roundedBezel
        timerMinutesField.frame = NSRect(x: 170, y: 8, width: 60, height: 24)
        let addBtn = ShroomButton(title: "Add Timer", icon: "⏱", color: FungiTheme.cap)
        addBtn.target = self; addBtn.action = #selector(addTimer)
        addBtn.frame = NSRect(x: 240, y: 8, width: 120, height: 26)
        timerAddLocal.addArrangedSubview(timerLabelField)
        timerAddLocal.addArrangedSubview(timerMinutesField)
        timerAddLocal.addArrangedSubview(addBtn)
        parent.addSubview(timerAddLocal)
        timerAdd = timerAddLocal
    }

    func buildMedia(in parent: NSView) {
        let mediaRowLocal = NSStackView()
        mediaRowLocal.orientation = .horizontal
        mediaRowLocal.distribution = .fillEqually
        mediaRowLocal.spacing = 12
        mediaRowLocal.frame = NSRect(x: 24, y: 180, width: 348, height: 60)
        let mediaCmds: [(String, MediaCommand)] = [("⏮", .previous), ("⏯", .toggle), ("⏭", .next)]
        for (i, (label, _)) in mediaCmds.enumerated() {
            let b = NSButton(title: label, target: self, action: #selector(mediaButton(_:)))
            b.tag = i
            b.bezelStyle = .inline
            b.isBordered = false
            b.font = NSFont.systemFont(ofSize: 28, weight: .light)
            b.contentTintColor = FungiTheme.gill
            b.wantsLayer = true
            b.layer?.cornerRadius = 30
            b.layer?.backgroundColor = FungiTheme.mycelium.cgColor
            mediaRowLocal.addArrangedSubview(b)
        }
        parent.addSubview(mediaRowLocal)
        mediaRow = mediaRowLocal

        mediaTitleLabel = SectionLabel("Media controls", font: FungiTheme.title)
        mediaTitleLabel.frame = NSRect(x: 24, y: 280, width: 348, height: 24)
        parent.addSubview(mediaTitleLabel)
        mediaHintLabel = SectionLabel("Tap to skip, pause, or play your tunes.", font: FungiTheme.body, color: FungiTheme.fog)
        mediaHintLabel.frame = NSRect(x: 24, y: 252, width: 348, height: 18)
        parent.addSubview(mediaHintLabel)

        lyricsToggle = NSButton(checkboxWithTitle: "🐦 Songbird — live line-synced lyrics (Music app)",
                                target: self, action: #selector(toggleLyrics))
        lyricsToggle.font = FungiTheme.body
        lyricsToggle.frame = NSRect(x: 24, y: 140, width: 348, height: 20)
        parent.addSubview(lyricsToggle)

        lyricsLabel = NSTextField(labelWithString: "")
        lyricsLabel.font = FungiTheme.subtitle
        lyricsLabel.textColor = FungiTheme.gill
        lyricsLabel.alignment = .center
        lyricsLabel.maximumNumberOfLines = 4
        lyricsLabel.lineBreakMode = .byWordWrapping
        lyricsLabel.frame = NSRect(x: 24, y: 30, width: 348, height: 100)
        parent.addSubview(lyricsLabel)
    }

    func buildFairyRing(in parent: NSView) {
        // Fairy Ring shows ALL 32 toadstools in a single 4-column grid so the
        // catalogue is fully visible the moment the tab is picked. The old
        // single-column NSTableView only fit ~12 rows and the scroll position
        // had to be reset every time the tab was reselected (was a bug source).
        // The grid view replaces the table entirely.
        sporeGrid = NSView(frame: NSRect(x: 14, y: 16, width: 348, height: 408))
        sporeGrid.wantsLayer = true
        sporeGrid.layer?.backgroundColor = FungiTheme.humus.cgColor
        sporeGrid.layer?.cornerRadius = 8
        parent.addSubview(sporeGrid)
        sporeGridCells = []
        sporeGridFlair = nil

        let cols = 4
        let rows = 8 // 32 / 4
        let cellWidth: CGFloat = 348 / CGFloat(cols) // 87
        let cellHeight: CGFloat = 408 / CGFloat(rows) // 51

        for (index, spore) in SporeManager.shared.spores.enumerated() {
            let col = index % cols
            let row = index / cols
            let cell = SporeCell(frame: NSRect(
                x: CGFloat(col) * cellWidth + 4,
                y: CGFloat(rows - 1 - row) * cellHeight + 4, // flip for macOS y-up
                width: cellWidth - 8,
                height: cellHeight - 8
            ))
            cell.sporeRef = WeakHolder(spore as AnyObject)
            cell.refresh()
            cell.onToggle = { [weak self] (holder: WeakHolder<AnyObject>) in
                guard let self = self, let s = holder.value as? Spore else { return }
                SporeManager.shared.toggle(s)
                self.refreshFairyRing()
                self.footerLabel.stringValue = s.enabled ? "✨ \(s.name) on" : "💤 \(s.name) off"
            }
            cell.onInfo = { [weak self] (holder: WeakHolder<AnyObject>) in
                guard let self = self, let s = holder.value as? Spore else { return }
                let info = SporeCell.infoText(for: s)
                self.footerLabel.stringValue = "\(s.icon) \(s.name): \(info)"
            }
            sporeGrid.addSubview(cell)
            sporeGridCells.append(cell)
        }

        sporeHint = SectionLabel("Double-click a toadstool to toggle it · ⓘ for setup", font: FungiTheme.body, color: FungiTheme.fog)
        sporeHint.frame = NSRect(x: 14, y: 0, width: 348, height: 14)
        parent.addSubview(sporeHint)
    }

    func refreshFairyRing() {
        for cell in sporeGridCells { cell.refresh() }
    }

    func buildSettings(in parent: NSView) {
        cloudStatusLabel = NSTextField(labelWithString: "Spore Cloud: starting…")
        cloudStatusLabel.font = FungiTheme.body
        cloudStatusLabel.textColor = FungiTheme.fog
        cloudStatusLabel.frame = NSRect(x: 14, y: 388, width: 370, height: 16)
        parent.addSubview(cloudStatusLabel)

        cloudToggleButton = NSButton(checkboxWithTitle: "Enable Spore Cloud (LAN sharing)", target: self, action: #selector(toggleCloud))
        cloudToggleButton.font = FungiTheme.body
        cloudToggleButton.frame = NSRect(x: 14, y: 364, width: 370, height: 20)
        parent.addSubview(cloudToggleButton)

        nightcapToggle = NSButton(checkboxWithTitle: "Show nightcap widgets when idle", target: self, action: #selector(toggleNightcap))
        nightcapToggle.font = FungiTheme.body
        nightcapToggle.frame = NSRect(x: 14, y: 332, width: 370, height: 20)
        parent.addSubview(nightcapToggle)

        nightcapHint = NSTextField(labelWithString: "Idle threshold default 5 min (UserDefaults: nightcap.idleMinutes)")
        nightcapHint.font = FungiTheme.mono
        nightcapHint.textColor = FungiTheme.whisper
        nightcapHint.frame = NSRect(x: 14, y: 314, width: 370, height: 14)
        parent.addSubview(nightcapHint)

        pillToggle = NSButton(checkboxWithTitle: "Show floating Burrow pill at top of screen", target: self, action: #selector(togglePill))
        pillToggle.font = FungiTheme.body
        pillToggle.frame = NSRect(x: 14, y: 286, width: 370, height: 20)
        parent.addSubview(pillToggle)

        launchAtLogin = NSButton(checkboxWithTitle: "Launch Fungi at login", target: self, action: #selector(toggleLaunchAtLogin))
        launchAtLogin.font = FungiTheme.body
        launchAtLogin.frame = NSRect(x: 14, y: 258, width: 370, height: 20)
        parent.addSubview(launchAtLogin)

        // --- Global hotkeys (KeyboardShortcuts recorders, scrollable) ---
        let chimesTitle = SectionLabel("🔔 Chimes — global hotkeys", font: FungiTheme.subtitle)
        chimesTitle.frame = NSRect(x: 14, y: 226, width: 240, height: 18)
        parent.addSubview(chimesTitle)
        shortcutRows.append(chimesTitle)

        let resetBtn = ShroomButton(title: "Reset", icon: "↺", color: FungiTheme.whisper)
        resetBtn.target = self; resetBtn.action = #selector(resetShortcuts)
        resetBtn.frame = NSRect(x: 292, y: 222, width: 92, height: 26)
        parent.addSubview(resetBtn)
        shortcutRows.append(resetBtn)

        let rowH: CGFloat = 30
        let docH = CGFloat(Chimes.all.count) * rowH
        let scroll = NSScrollView(frame: NSRect(x: 14, y: 44, width: 370, height: 172))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 10

        let doc = NSView(frame: NSRect(x: 0, y: 0, width: 352, height: docH))
        for (i, (label, name)) in Chimes.all.enumerated() {
            // Lay out top-down in the document's flipped-from-the-top ordering.
            let y = docH - CGFloat(i + 1) * rowH + 3

            let l = SectionLabel(label, font: FungiTheme.body, color: FungiTheme.fog)
            l.frame = NSRect(x: 6, y: y + 2, width: 176, height: 18)
            doc.addSubview(l)

            let recorder = KeyboardShortcuts.RecorderCocoa(for: name)
            recorder.frame = NSRect(x: 190, y: y, width: 156, height: 24)
            doc.addSubview(recorder)
        }
        scroll.documentView = doc
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, docH - 172)))
        parent.addSubview(scroll)
        shortcutRows.append(scroll)

        let footer = SectionLabel("Fungi · MIT · built on Swifter, SimplyCoreAudio & KeyboardShortcuts",
                                  font: FungiTheme.mono, color: FungiTheme.whisper)
        footer.frame = NSRect(x: 14, y: 16, width: 370, height: 18)
        parent.addSubview(footer)
        shortcutRows.append(footer)
    }

    @objc func resetShortcuts() {
        KeyboardShortcuts.reset(Chimes.all.map(\.1))
        footerLabel.stringValue = "Chimes reset to their default hotkeys"
    }

    // MARK: - Actions

    @objc func mediaButton(_ sender: NSButton) {
        let cmds: [MediaCommand] = [.previous, .toggle, .next]
        MediaController.send(cmds[sender.tag])
    }

    @objc func addTimer() {
        let mins = Int(timerMinutesField.stringValue) ?? 25
        let label = timerLabelField.stringValue.isEmpty ? "Timer" : timerLabelField.stringValue
        timerManager?.minutes = mins
        timerManager?.label = label
        timerManager?.add()
        timerList.reloadData()
        footerLabel.stringValue = "Spored a \(mins)-minute timer: \(label)"
    }

    @objc func doubleClickRow() {
        let row: Int
        switch currentTab {
        case .pantry: row = clipTable.clickedRow
        case .basket: row = fileTable.clickedRow
        case .timers: row = timerList.clickedRow
        case .fairyring: row = sporeTable.clickedRow
        default: return
        }
        switch currentTab {
        case .pantry:
            if row >= 0, let item = clipboard?.filtered[safe: row] {
                clipboard?.copy(item); footerLabel.stringValue = "Copied: \(item.preview.prefix(40))"
            }
        case .basket:
            if row >= 0 {
                let files = Storage.shared.basketFiles()
                if row < files.count {
                    NSWorkspace.shared.activateFileViewerSelecting([files[row]])
                    footerLabel.stringValue = "Revealed \(files[row].lastPathComponent)"
                }
            }
        case .timers:
            if row >= 0, let t = timerManager?.timers[safe: row] {
                timerManager?.cancel(t.id); timerList.reloadData()
                footerLabel.stringValue = "Timer cancelled"
            }
        case .fairyring:
            if row >= 0 {
                let spores = SporeManager.shared.spores
                if row < spores.count {
                    let s = spores[row]
                    SporeManager.shared.toggle(s)
                    sporeTable.reloadData()
                    footerLabel.stringValue = "\(s.enabled ? "Bloomed" : "Slept"): \(s.name)"
                }
            }
        default: break
        }
    }

    @objc func shareFile() {
        let pick = NSOpenPanel()
        pick.canChooseFiles = true
        pick.allowsMultipleSelection = false
        pick.directoryURL = Storage.shared.basketDir
        pick.message = "Pick a file to share via AirDrop / Messages / Mail"
        guard pick.runModal() == .OK, let url = pick.url else { return }
        let picker = NSSharingServicePicker(items: [url])
        picker.show(relativeTo: NSZeroRect, of: view, preferredEdge: .minY)
    }

    @objc func copyShareLink() {
        let pick = NSOpenPanel()
        pick.canChooseFiles = true
        pick.allowsMultipleSelection = false
        pick.directoryURL = Storage.shared.basketDir
        pick.message = "Pick a file to generate a LAN share link"
        guard pick.runModal() == .OK, let url = pick.url else { return }
        guard let link = SporeCloud.shared.link(for: url.lastPathComponent) else {
            footerLabel.stringValue = "Spore Cloud not running — enable in Settings"
            return
        }
        let pb = NSPasteboard.general; pb.clearContents()
        pb.setString(link, forType: .string)
        footerLabel.stringValue = "Copied: \(link)"
    }

    @objc func openBasketIndex() {
        guard let link = SporeCloud.shared.indexLink(), let url = URL(string: link) else {
            footerLabel.stringValue = "Spore Cloud not running — enable in Settings"
            return
        }
        NSWorkspace.shared.open(url)
        let pb = NSPasteboard.general; pb.clearContents(); pb.setString(link, forType: .string)
        footerLabel.stringValue = "Basket index open — link copied: \(link)"
    }

    @objc func toggleCloud() {
        if SporeCloud.shared.isRunning {
            SporeCloud.shared.stop()
        } else {
            SporeCloud.shared.start { [weak self] in
                DispatchQueue.main.async { self?.refreshCloudStateSafe() }
            }
        }
    }

    @objc func toggleNightcap() {
        NightcapController.shared.enabled.toggle()
        if NightcapController.shared.enabled && !NightcapController.shared.isShown {
            NightcapController.shared.show()
        } else if !NightcapController.shared.enabled {
            NightcapController.shared.hide()
        }
    }

    @objc func togglePill() {
        NotificationCenter.default.post(name: NSNotification.Name("FungiTogglePill"), object: nil)
        pillToggle.state = (UserDefaults.standard.bool(forKey: "showPill")) ? .on : .off
    }

    @objc func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            footerLabel.stringValue = "Launch-at-login failed: \(error.localizedDescription)"
        }
        launchAtLogin.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
    }

    func refreshCloudState() {
        if SporeCloud.shared.isRunning {
            cloudStatusLabel.stringValue = "Spore Cloud: running — share via Copy link in Basket"
            cloudStatusLabel.textColor = FungiTheme.moss
        } else {
            cloudStatusLabel.stringValue = "Spore Cloud: paused — toggle below to start LAN sharing"
            cloudStatusLabel.textColor = FungiTheme.cap
        }
    }

    func refreshCloudStateSafe() { if isViewLoaded { refreshCloudState() } }

    // MARK: - NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int {
        switch tableView {
        case clipTable: return clipboard?.filtered.count ?? 0
        case fileTable: return Storage.shared.basketFiles().count
        case timerList: return timerManager?.timers.count ?? 0
        case sporeTable: return SporeManager.shared.spores.count
        default: return 0
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        cell.wantsLayer = true
        cell.layer?.cornerRadius = 10
        cell.layer?.backgroundColor = FungiTheme.mycelium.withAlphaComponent(0.6).cgColor
        let tf = NSTextField(labelWithString: "")
        tf.textColor = FungiTheme.ink
        tf.font = FungiTheme.body
        tf.lineBreakMode = .byTruncatingTail
        tf.drawsBackground = false
        switch tableView {
        case clipTable:
            if let item = clipboard?.filtered[safe: row] {
                tf.stringValue = "\(item.preview)"
                tf.font = FungiTheme.mono
            }
        case fileTable:
            let files = Storage.shared.basketFiles()
            if row < files.count {
                let url = files[row]
                let attrs = try? url.resourceValues(forKeys: [.fileSizeKey])
                let size = attrs?.fileSize ?? 0
                let f = ByteCountFormatter(); f.countStyle = .file
                tf.stringValue = "🧺  \(url.lastPathComponent)  ·  \(f.string(fromByteCount: Int64(size)))"
            }
        case timerList:
            if let t = timerManager?.timers[safe: row] {
                let remaining = max(0, t.fireDate.timeIntervalSinceNow)
                let m = Int(remaining) / 60, s = Int(remaining) % 60
                tf.stringValue = "⏱  \(t.label)   \(m):\(String(format: "%02d", s))"
                tf.font = FungiTheme.mono
            }
        case sporeTable:
            let spores = SporeManager.shared.spores
            if row < spores.count {
                let s = spores[row]
                let mark = s.enabled ? "●" : "○"
                tf.stringValue = "\(mark)  \(s.icon)  \(s.name)  —  \(s.statusText)"
            }
        default: break
        }
        tf.frame = NSRect(x: 12, y: 8, width: 360, height: 20)
        cell.addSubview(tf)
        return cell
    }

    func controlTextDidChange(_ obj: Notification) {
        if let cb = clipboard {
            cb.search = searchField.stringValue
            clipTable.reloadData()
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

extension String {
    var htmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - SporeCell (Fairy Ring grid)

final class SporeCell: NSView {
    var sporeRef: WeakHolder<AnyObject>?
    var onToggle: ((WeakHolder<AnyObject>) -> Void)?
    var onInfo: ((WeakHolder<AnyObject>) -> Void)?

    private let iconLabel = NSTextField(labelWithString: "")
    private let nameLabel = NSTextField(labelWithString: "")
    private let infoBtn = NSButton(title: "ⓘ", target: nil, action: nil)
    private let ring = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8

        ring.wantsLayer = true
        ring.layer?.borderWidth = 1
        ring.layer?.borderColor = FungiTheme.cap.withAlphaComponent(0.4).cgColor
        ring.layer?.cornerRadius = 7
        addSubview(ring)
        ring.frame = bounds

        iconLabel.font = NSFont.systemFont(ofSize: 18)
        iconLabel.alignment = .center
        iconLabel.frame = NSRect(x: 0, y: 22, width: bounds.width, height: 22)
        addSubview(iconLabel)

        nameLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        nameLabel.frame = NSRect(x: 2, y: 6, width: bounds.width - 4, height: 12)
        addSubview(nameLabel)

        infoBtn.font = NSFont.systemFont(ofSize: 9)
        infoBtn.bezelStyle = .circular
        infoBtn.isBordered = false
        infoBtn.frame = NSRect(x: bounds.width - 16, y: 2, width: 14, height: 14)
        addSubview(infoBtn)

        let click = NSClickGestureRecognizer(target: self, action: #selector(toggle))
        addGestureRecognizer(click)
        infoBtn.target = self
        infoBtn.action = #selector(showInfo)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        ring.frame = bounds
        iconLabel.frame = NSRect(x: 0, y: bounds.height - 28, width: bounds.width, height: 20)
        nameLabel.frame = NSRect(x: 2, y: 6, width: bounds.width - 4, height: 12)
        infoBtn.frame = NSRect(x: bounds.width - 16, y: 2, width: 14, height: 14)
    }

    func refresh() {
        guard let spore = sporeRef?.value as? Spore else { return }
        iconLabel.stringValue = spore.icon
        nameLabel.stringValue = spore.name
        if spore.enabled {
            layer?.backgroundColor = FungiTheme.mycelium.withAlphaComponent(0.7).cgColor
            ring.layer?.borderColor = FungiTheme.spore.withAlphaComponent(0.9).cgColor
            ring.layer?.borderWidth = 1.5
            nameLabel.textColor = FungiTheme.ink
            iconLabel.alphaValue = 1.0
        } else {
            layer?.backgroundColor = FungiTheme.canopy.withAlphaComponent(0.6).cgColor
            ring.layer?.borderColor = FungiTheme.cap.withAlphaComponent(0.25).cgColor
            ring.layer?.borderWidth = 1
            nameLabel.textColor = FungiTheme.fog
            iconLabel.alphaValue = 0.55
        }
    }

    @objc func toggle() { if let r = sporeRef { onToggle?(r) } }
    @objc func showInfo() { if let r = sporeRef { onInfo?(r) } }

    /// Setup blurb per spore. Used by the ⓘ button.
    static func infoText(for spore: Spore) -> String {
        switch spore.id {
        case "pomodoro":  return "25-min focus timer. Toggle on then press ⌥⌘P from anywhere to start."
        case "truffle":   return "Smart paste: transforms clipboard content (markdown→rich text, JSON→pretty, etc.). Toggle to enable."
        case "bamboo":    return "Snippets — type ;shortcut anywhere to expand a saved snippet. Toggle to register."
        case "morel":     return "Quick capture — shortcut opens a small note taker, saved to iCloud Notes."
        case "clover":    return "Window presets — ⌥⌘←/→/↑ snap to halves & corners. Requires Accessibility access."
        case "battery":   return "Adds a battery badge next to the menu bar icon. No permission needed."
        case "system-stats": return "CPU/RAM/disk summary in the Burrow footer. Updates every minute."
        case "network":   return "Shows current Wi-Fi name + latency in the Burrow footer. Auto refresh."
        case "stalk":     return "Battery alert at 20% with an opt-in chime. Customizable threshold."
        case "lichen":    return "Clipboard size summary — current and longest this session."
        case "moth":      return "Visual chime — a one-time shimmer on sends/receives. Press ⌥⌘M to fire."
        case "capstone":  return "Word/char/line counts for the active text editor (TextEdit, Pages, etc.)."
        case "pollen":    return "Pollen-style ambient sound — gentle forest hum when the Mac is idle."
        case "weather":   return "Current temperature in the menu bar. Uses macOS WeatherKit, no API key needed."
        case "calendar":  return "Surfaces the next calendar event in the menu bar. First run asks for Calendar access."
        case "fern":      return "Daily focus time goal — the Burrow tells you when you've hit your daily minimum."
        case "mycelium":  return "Cross-device clipboard: copy on the iPhone, paste on the Mac. No additional app needed."
        case "pin":       return "Pin frequently used toadstools to the top of the Burrow status line."
        case "bee":       return "Weekly screenshot of the Burrow — saved automatically to iCloud BurrowArchive/."
        case "conifer":   return "Quick file opener — ⌥⌘F opens any path with FuzzyFinder-style search."
        case "maple":     return "Pick colors anywhere on screen. Press ⌥⌘C to drop a hex into the active app."
        case "fox":       return "Git status dot — repo + branch + dirty count. Polls every minute."
        case "warbler":   return "Ambient bird sounds on every macOS notification. Toggle when you want a break."
        case "quill":     return "Hashes the clipboard text (SHA-256 prefix). Useful for verifying shares."
        case "cricket":   return "Key-press sound effects. Asks for Input Monitoring access the first time."
        case "familiar":  return "Watches for claude/code sessions to be running and surfaces them in the Burrow."
        case "frontmost-url": return "Shows the frontmost browser URL in the menu bar. Updates every 3 seconds."
        case "root":      return "Counts the open Finder windows. Useful for quick declutter sanity checks."
        case "sporework": return "Indexes open windows across apps. Tells you what you actually have running."
        case "bloom":     return "Daily app-launch tally. The Burrow tells you what you used today at 6pm."
        case "husk":      return "Tracks the largest thing on your clipboard today. Auto expires at midnight."
        case "leaf":      return "UserDefaults-driven scriptable hook. Set 'spores.leaf.script' to a shell path."
        default:           return "No setup required — just toggle it on to enable."
        }
    }
}

// MARK: - Main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
