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
    let dropsDir: URL?
    let clipsFile: URL
    let timersFile: URL
    let imagesDir: URL

    private init() {
        let fm = FileManager.default
        let base = try! fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        supportDir = base.appendingPathComponent("Shelf", isDirectory: true)
        try? fm.createDirectory(at: supportDir, withIntermediateDirectories: true)

        // iCloud Drive location
        var cloud: URL? = nil
        if let cloudBase = fm.url(forUbiquityContainerIdentifier: nil) {
            cloud = cloudBase.appendingPathComponent("Documents/Shelf", isDirectory: true)
            try? fm.createDirectory(at: cloud!, withIntermediateDirectories: true)
        } else {
            // Fallback: direct iCloud Drive folder path
            let home = FileManager.default.homeDirectoryForCurrentUser
            let alt = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Shelf", isDirectory: true)
            if fm.fileExists(atPath: alt.path) || (try? fm.createDirectory(at: alt, withIntermediateDirectories: true)) != nil {
                cloud = alt
            }
        }
        icloudDir = cloud
        dropsDir = cloud?.appendingPathComponent("Drops", isDirectory: true)
        if let d = dropsDir { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }

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

    /// Files dropped into the tray (live listing of Drops dir)
    func droppedFiles() -> [URL] {
        guard let d = dropsDir else { return [] }
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
    func importDrop(from src: URL) -> URL? {
        guard let d = dropsDir else { return nil }
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
    }

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

final class DropView: NSView {
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
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 40),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 40))
        container.wantsLayer = true
        container.layer?.cornerRadius = 20
        container.layer?.backgroundColor = NSColor(calibratedRed: 0.1, green: 0.1, blue: 0.14, alpha: 0.92).cgColor
        panel.contentView = container

        timeLabel = NSTextField(labelWithString: "")
        timeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        timeLabel.textColor = .white
        timeLabel.frame = NSRect(x: 14, y: 11, width: 70, height: 18)
        container.addSubview(timeLabel)

        clipLabel = NSTextField(labelWithString: "📋 0")
        clipLabel.font = NSFont.systemFont(ofSize: 12)
        clipLabel.textColor = NSColor(white: 0.75, alpha: 1)
        clipLabel.frame = NSRect(x: 92, y: 11, width: 60, height: 18)
        container.addSubview(clipLabel)

        let btn = NSButton(title: "⏯", target: self, action: #selector(playPause))
        btn.isBordered = false
        btn.font = NSFont.systemFont(ofSize: 12)
        btn.contentTintColor = .white
        btn.frame = NSRect(x: 158, y: 9, width: 28, height: 22)
        container.addSubview(btn)

        let open = NSButton(title: "▦", target: self, action: #selector(openShelf))
        open.isBordered = false
        open.font = NSFont.systemFont(ofSize: 12)
        open.contentTintColor = .white
        open.frame = NSRect(x: 188, y: 9, width: 28, height: 22)
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
    @objc private func openShelf() { onToggle?() }
}

// MARK: - Droplets (extension system)

protocol Droplet: AnyObject {
    var id: String { get }
    var name: String { get }
    var icon: String { get }
    var enabled: Bool { get set }
    var statusText: String { get }
    func start()
    func stop()
}

final class PomodoroDroplet: Droplet {
    let id = "pomodoro"
    let name = "Pomodoro"
    let icon = "🍅"
    var enabled = UserDefaults.standard.bool(forKey: "droplet.pomodoro") { didSet { UserDefaults.standard.set(enabled, forKey: "droplet.pomodoro") } }
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

final class BatteryDroplet: Droplet {
    let id = "battery"
    let name = "Battery monitor"
    let icon = "🔋"
    var enabled = UserDefaults.standard.bool(forKey: "droplet.battery") { didSet { UserDefaults.standard.set(enabled, forKey: "droplet.battery") } }
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
        guard let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as? [CFTypeRef], !sources.isEmpty else {
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

final class WeatherDroplet: Droplet {
    let id = "weather"
    let name = "Weather"
    let icon = "🌤"
    var enabled = UserDefaults.standard.bool(forKey: "droplet.weather") { didSet { UserDefaults.standard.set(enabled, forKey: "droplet.weather") } }
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

final class DropletManager {
    static let shared = DropletManager()
    let droplets: [Droplet] = [PomodoroDroplet(), BatteryDroplet(), WeatherDroplet()]
    var refreshUI: (() -> Void)?
    private init() {
        for d in droplets where d.enabled { d.start() }
    }
    func toggle(_ d: Droplet) {
        d.enabled.toggle()
        if d.enabled { d.start() } else { d.stop() }
        refreshUI?()
    }
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
        statusItem.button?.title = "◰"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 480, height: 600)
        popover.contentViewController = popoverVC
        popoverVC.clipboard = clipboard
        popoverVC.timerManager = timerManager
        popoverVC.onPillToggle = { [weak self] in self?.togglePill() }
        clipboard.start()
        timerManager.start()
        _ = DropletManager.shared
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.timerManager.tick()
        }
        if showPill { togglePill() }
        // Refresh droplet status every 5s so the UI shows live updates
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self = self, self.popoverVC.currentTab == 4 else { return }
            self.popoverVC.dropletTable.reloadData()
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
        popoverVC.refreshPillState(showPill)
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

    func applicationShouldTerminateAfterLastWindowClosure(_ sender: NSApplication) -> Bool { false }
}

// MARK: - Popover View

final class PopoverViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    weak var clipboard: ClipboardManager?
    weak var timerManager: TimerManager?
    var onPillToggle: (() -> Void)?
    let tabs = ["Clipboard", "Files", "Timers", "Media", "Droplets", "Settings"]
    var currentTab = 0
    var tabButtons: [NSButton] = []
    let searchField = NSTextField()
    let clipTable = NSTableView()
    let fileTable = NSTableView()
    let timerList = NSTableView()
    var timerLabelField: NSTextField!
    var timerMinutesField: NSTextField!
    var statusLabel: NSTextField!
    var launchAtLogin: NSButton!
    var pillToggle: NSButton!
    var icloudLabel: NSTextField!
    var dropView: DropView!
    var mediaRow: NSStackView!
    var timerAdd: NSStackView!
    var dropletTable: NSTableView!
    var shareButton: NSButton!
    var dropletHint: NSTextField!

    override func loadView() {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 600))
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 1.0).cgColor

        // Header
        let header = NSView(frame: NSRect(x: 0, y: 560, width: 480, height: 40))
        header.wantsLayer = true
        header.layer?.backgroundColor = NSColor(calibratedWhite: 0.16, alpha: 1.0).cgColor
        v.addSubview(header)

        let title = NSTextField(labelWithString: "Shelf")
        title.font = NSFont.systemFont(ofSize: 16, weight: .bold)
        title.textColor = .white
        title.frame = NSRect(x: 16, y: 10, width: 200, height: 22)
        header.addSubview(title)

        icloudLabel = NSTextField(labelWithString: Storage.shared.usingICloud ? "☁️ iCloud" : "⚠️ Local only")
        icloudLabel.font = NSFont.systemFont(ofSize: 11)
        icloudLabel.textColor = Storage.shared.usingICloud ? NSColor(calibratedRed: 0.4, green: 0.85, blue: 0.5, alpha: 1) : NSColor.systemOrange
        icloudLabel.frame = NSRect(x: 380, y: 12, width: 90, height: 18)
        header.addSubview(icloudLabel)

        // Tabs
        let tabStack = NSStackView()
        tabStack.orientation = .horizontal
        tabStack.distribution = .fillEqually
        tabStack.spacing = 0
        tabStack.frame = NSRect(x: 0, y: 520, width: 480, height: 36)
        for (i, t) in tabs.enumerated() {
            let b = NSButton(title: t, target: self, action: #selector(switchTab(_:)))
            b.tag = i
            b.bezelStyle = .inline
            b.isBordered = false
            b.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            b.contentTintColor = (i == currentTab) ? .white : NSColor(white: 0.6, alpha: 1)
            b.wantsLayer = true
            b.layer?.backgroundColor = (i == currentTab ? NSColor(calibratedRed: 0.2, green: 0.5, blue: 0.9, alpha: 1) : .clear).cgColor
            tabStack.addArrangedSubview(b)
            tabButtons.append(b)
        }
        v.addSubview(tabStack)

        // Search
        searchField.placeholderString = "Search clipboard…"
        searchField.delegate = self
        searchField.frame = NSRect(x: 12, y: 486, width: 456, height: 26)
        searchField.bezelStyle = .roundedBezel
        v.addSubview(searchField)

        // Tables
        configureTable(clipTable)
        configureTable(fileTable)
        configureTable(timerList)
        clipTable.frame = NSRect(x: 0, y: 120, width: 480, height: 360)
        fileTable.frame = NSRect(x: 0, y: 120, width: 480, height: 320)
        timerList.frame = NSRect(x: 0, y: 120, width: 480, height: 320)
        v.addSubview(clipTable)
        v.addSubview(fileTable)
        v.addSubview(timerList)

        // Drop zone (Files tab)
        dropView = DropView(frame: NSRect(x: 12, y: 448, width: 456, height: 62))
        dropView.label = "Drop files here → saved to iCloud Drive"
        dropView.onDrop = { [weak self] url in
            _ = Storage.shared.importDrop(from: url)
            self?.fileTable.reloadData()
            self?.statusLabel.stringValue = "Imported \(url.lastPathComponent) → iCloud Drops"
        }
        dropView.isHidden = true
        v.addSubview(dropView)

        // Share button (Files tab) — share selected file via AirDrop/Messages/Mail
        shareButton = NSButton(title: "↗️ Share…", target: self, action: #selector(shareFile))
        shareButton.bezelStyle = .rounded
        shareButton.font = NSFont.systemFont(ofSize: 12)
        shareButton.frame = NSRect(x: 12, y: 416, width: 100, height: 26)
        shareButton.isHidden = true
        v.addSubview(shareButton)

        // Droplets table
        dropletTable = NSTableView()
        let dcol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("d"))
        dcol.width = 460
        dropletTable.addTableColumn(dcol)
        dropletTable.headerView = nil
        dropletTable.dataSource = self
        dropletTable.delegate = self
        dropletTable.backgroundColor = .clear
        dropletTable.frame = NSRect(x: 0, y: 160, width: 480, height: 300)
        dropletTable.isHidden = true
        v.addSubview(dropletTable)

        // Droplet detail (toggle + refresh buttons) — simple: use a table with checkbox cells instead
        let dropletHint = NSTextField(labelWithString: "Toggle a droplet to enable it. Droplets run in the background and notify you.")
        dropletHint.textColor = NSColor(white: 0.6, alpha: 1)
        dropletHint.font = NSFont.systemFont(ofSize: 11)
        dropletHint.frame = NSRect(x: 12, y: 470, width: 456, height: 18)
        dropletHint.isHidden = true
        v.addSubview(dropletHint)
        self.dropletHint = dropletHint

        // Media buttons row
        let mediaRowLocal = NSStackView()
        mediaRowLocal.orientation = .horizontal
        mediaRowLocal.distribution = .fillEqually
        mediaRowLocal.spacing = 8
        mediaRowLocal.frame = NSRect(x: 12, y: 80, width: 456, height: 40)
        let mediaCmds: [(String, MediaCommand)] = [("⏮", .previous), ("⏯", .toggle), ("⏭", .next)]
        for (i, (label, _)) in mediaCmds.enumerated() {
            let b = NSButton(title: label, target: self, action: #selector(mediaButton(_:)))
            b.tag = i
            b.bezelStyle = .rounded
            b.font = NSFont.systemFont(ofSize: 18)
            mediaRowLocal.addArrangedSubview(b)
        }
        mediaRowLocal.isHidden = true
        v.addSubview(mediaRowLocal)
        self.mediaRow = mediaRowLocal

        // Timer add row
        let timerAddLocal = NSStackView()
        timerAddLocal.orientation = .horizontal
        timerAddLocal.spacing = 6
        timerAddLocal.frame = NSRect(x: 12, y: 36, width: 456, height: 40)
        timerLabelField = NSTextField(string: "")
        timerLabelField.placeholderString = "Label"
        timerLabelField.bezelStyle = .roundedBezel
        timerLabelField.frame = NSRect(x: 0, y: 8, width: 160, height: 24)
        timerMinutesField = NSTextField(string: "25")
        timerMinutesField.bezelStyle = .roundedBezel
        timerMinutesField.frame = NSRect(x: 170, y: 8, width: 60, height: 24)
        let addBtn = NSButton(title: "Add Timer", target: self, action: #selector(addTimer))
        addBtn.bezelStyle = .rounded
        addBtn.frame = NSRect(x: 240, y: 8, width: 110, height: 24)
        timerAddLocal.addArrangedSubview(timerLabelField)
        timerAddLocal.addArrangedSubview(timerMinutesField)
        timerAddLocal.addArrangedSubview(addBtn)
        timerAddLocal.isHidden = true
        v.addSubview(timerAddLocal)
        self.timerAdd = timerAddLocal

        // Settings rows
        launchAtLogin = NSButton(checkboxWithTitle: "Launch Shelf at login", target: self, action: #selector(toggleLaunchAtLogin))
        launchAtLogin.frame = NSRect(x: 16, y: 130, width: 300, height: 22)
        launchAtLogin.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        launchAtLogin.isHidden = true
        v.addSubview(launchAtLogin)

        pillToggle = NSButton(checkboxWithTitle: "Show floating pill (Dynamic Island style)", target: self, action: #selector(togglePillBtn))
        pillToggle.frame = NSRect(x: 16, y: 102, width: 300, height: 22)
        pillToggle.state = UserDefaults.standard.bool(forKey: "showPill") ? .on : .off
        pillToggle.isHidden = true
        v.addSubview(pillToggle)

        // Footer status
        statusLabel = NSTextField(labelWithString: "Ready")
        statusLabel.textColor = NSColor(white: 0.6, alpha: 1)
        statusLabel.font = NSFont.systemFont(ofSize: 10)
        statusLabel.frame = NSRect(x: 12, y: 0, width: 456, height: 14)
        v.addSubview(statusLabel)

        self.view = v
    }

    func refreshPillState(_ shown: Bool) {
        pillToggle.state = shown ? .on : .off
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        clipTable.reloadData()
        fileTable.reloadData()
        timerList.reloadData()
    }

    private func configureTable(_ t: NSTableView) {
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c"))
        col.width = 460
        t.addTableColumn(col)
        t.headerView = nil
        t.dataSource = self
        t.delegate = self
        t.backgroundColor = .clear
        t.target = self
        t.doubleAction = #selector(doubleClickRow)
        t.rowHeight = 28
    }

    @objc func switchTab(_ sender: NSButton) {
        currentTab = sender.tag
        for (i, b) in tabButtons.enumerated() {
            b.contentTintColor = (i == currentTab) ? .white : NSColor(white: 0.6, alpha: 1)
            b.layer?.backgroundColor = (i == currentTab ? NSColor(calibratedRed: 0.2, green: 0.5, blue: 0.9, alpha: 1) : .clear).cgColor
        }
        clipTable.isHidden = currentTab != 0
        fileTable.isHidden = currentTab != 1
        timerList.isHidden = currentTab != 2
        searchField.isHidden = currentTab != 0
        dropView?.isHidden = currentTab != 1
        shareButton?.isHidden = currentTab != 1
        mediaRow?.isHidden = currentTab != 3
        timerAdd?.isHidden = currentTab != 2
        dropletTable.isHidden = currentTab != 4
        dropletHint.isHidden = currentTab != 4
        launchAtLogin.isHidden = currentTab != 5
        pillToggle.isHidden = currentTab != 5
        if currentTab == 1 { fileTable.reloadData() }
        if currentTab == 2 { timerList.reloadData() }
        if currentTab == 4 { dropletTable.reloadData() }
        if currentTab == 5 { refreshPillState(UserDefaults.standard.bool(forKey: "showPill")) }
    }

    @objc func mediaButton(_ sender: NSButton) {
        let cmds: [MediaCommand] = [.previous, .toggle, .next]
        MediaController.send(cmds[sender.tag])
        statusLabel.stringValue = "Media: \(cmds[sender.tag].rawValue)"
    }

    @objc func addTimer() {
        guard let tm = timerManager else { return }
        tm.label = timerLabelField.stringValue
        if let m = Int(timerMinutesField.stringValue) { tm.minutes = m }
        tm.add()
        timerList.reloadData()
        statusLabel.stringValue = "Timer added: \(tm.minutes)m"
    }

    @objc func toggleLaunchAtLogin() {
        let svc = SMAppService.mainApp
        do {
            if launchAtLogin.state == .on {
                try svc.register()
            } else {
                try svc.unregister()
            }
        } catch {
            statusLabel.stringValue = "Login item error: \(error.localizedDescription)"
        }
    }

    @objc func togglePillBtn() {
        onPillToggle?()
    }

    @objc func doubleClickRow() {
        let row = (currentTab == 0 ? clipTable.clickedRow : currentTab == 1 ? fileTable.clickedRow : timerList.clickedRow)
        if currentTab == 0, row >= 0, let item = clipboard?.filtered[safe: row] {
            clipboard?.copy(item)
            statusLabel.stringValue = "Copied to clipboard"
        } else if currentTab == 1, row >= 0 {
            let files = Storage.shared.droppedFiles()
            if row < files.count {
                NSWorkspace.shared.activateFileViewerSelecting([files[row]])
                statusLabel.stringValue = "Revealed in Finder"
            }
        } else if currentTab == 2, row >= 0, let timer = timerManager?.timers[safe: row] {
            timerManager?.cancel(timer.id)
            timerList.reloadData()
            statusLabel.stringValue = "Timer cancelled"
        } else if currentTab == 4, row >= 0 {
            let droplets = DropletManager.shared.droplets
            if row < droplets.count {
                DropletManager.shared.toggle(droplets[row])
                dropletTable.reloadData()
                statusLabel.stringValue = "Toggled \(droplets[row].name)"
            }
        }
    }

    @objc func shareFile() {
        let files = Storage.shared.droppedFiles()
        guard !files.isEmpty else { statusLabel.stringValue = "No files to share"; return }
        let pick = NSOpenPanel()
        pick.canChooseFiles = true
        pick.allowsMultipleSelection = false
        pick.directoryURL = Storage.shared.dropsDir
        pick.message = "Select a file to share via AirDrop / Messages / Mail"
        if pick.runModal() == .OK, let url = pick.url {
            let picker = NSSharingServicePicker(items: [url])
            let anchor = view.window?.contentView ?? view
            picker.show(relativeTo: NSZeroRect, of: anchor, preferredEdge: .minY)
        }
    }

    // NSTableView
    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView == clipTable { return clipboard?.filtered.count ?? 0 }
        if tableView == fileTable { return Storage.shared.droppedFiles().count }
        if tableView == timerList { return timerManager?.timers.count ?? 0 }
        if tableView == dropletTable { return DropletManager.shared.droplets.count }
        return 0
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        let tf = NSTextField(labelWithString: "")
        tf.textColor = .white
        tf.font = NSFont.systemFont(ofSize: 12)
        tf.lineBreakMode = .byTruncatingTail
        if tableView == clipTable, let item = clipboard?.filtered[safe: row] {
            tf.stringValue = item.preview
        } else if tableView == fileTable {
            let files = Storage.shared.droppedFiles()
            if row < files.count {
                let url = files[row]
                let attrs = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let size = attrs?.fileSize ?? 0
                let formatter = ByteCountFormatter()
                formatter.countStyle = .file
                tf.stringValue = "📄 \(url.lastPathComponent)  (\(formatter.string(fromByteCount: Int64(size))))"
            }
        } else if tableView == timerList, let t = timerManager?.timers[safe: row] {
            let remaining = max(0, t.fireDate.timeIntervalSinceNow)
            let m = Int(remaining) / 60
            let s = Int(remaining) % 60
            tf.stringValue = "\(t.label)  \(m):\(String(format: "%02d", s))"
        } else if tableView == dropletTable {
            let droplets = DropletManager.shared.droplets
            if row < droplets.count {
                let d = droplets[row]
                let mark = d.enabled ? "●" : "○"
                tf.stringValue = "\(mark) \(d.icon)  \(d.name)  —  \(d.statusText)"
            }
        }
        tf.frame = NSRect(x: 8, y: 4, width: 460, height: 20)
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

// MARK: - Main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
