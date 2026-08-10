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
    let droplets: [Droplet] = [PomodoroDroplet(), BatteryDroplet(), WeatherDroplet(), CalendarDroplet(), FrontmostURLDroplet(), SystemStatsDroplet(), NetworkDroplet()]
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

// MARK: - Calendar droplet (EventKit)

final class CalendarDroplet: Droplet {
    let id = "calendar"
    let name = "Calendar"
    let icon = "📅"
    var enabled = UserDefaults.standard.bool(forKey: "droplet.calendar") { didSet { UserDefaults.standard.set(enabled, forKey: "droplet.calendar") } }
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
            statusText = "\(next.title) @ \(f.string(from: next.startDate))"
        } else {
            statusText = "No upcoming events"
        }
    }
}

// MARK: - Frontmost URL droplet (Safari/Chrome)

final class FrontmostURLDroplet: Droplet {
    let id = "frontmost-url"
    let name = "Frontmost URL"
    let icon = "🌐"
    var enabled = UserDefaults.standard.bool(forKey: "droplet.frontmost-url") { didSet { UserDefaults.standard.set(enabled, forKey: "droplet.frontmost-url") } }
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

// MARK: - System stats droplet

final class SystemStatsDroplet: Droplet {
    let id = "system-stats"
    let name = "System stats"
    let icon = "💻"
    var enabled = UserDefaults.standard.bool(forKey: "droplet.system-stats") { didSet { UserDefaults.standard.set(enabled, forKey: "droplet.system-stats") } }
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

// MARK: - Network droplet (SSID + latency)

final class NetworkDroplet: Droplet {
    let id = "network"
    let name = "Network"
    let icon = "📶"
    var enabled = UserDefaults.standard.bool(forKey: "droplet.network") { didSet { UserDefaults.standard.set(enabled, forKey: "droplet.network") } }
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

// MARK: - Shelf Cloud (LAN share links + iCloud share sheet)

final class ShelfCloud {
    static let shared = ShelfCloud()
    var isRunning = false
    private var listener: NWListener?
    private var statusChanged: (() -> Void)?

    func start(statusChanged: @escaping () -> Void) {
        self.statusChanged = statusChanged
        do {
            listener = try NWListener(using: .tcp, on: 8420)
            listener?.newConnectionHandler = { [weak self] conn in
                self?.handle(conn)
            }
            listener?.start(queue: .global())
            isRunning = true
        } catch {
            isRunning = false
        }
        statusChanged()
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        statusChanged?()
    }

    /// Serve one HTTP GET and close. Files served from Drops dir.
    private func handle(_ conn: NWConnection) {
        conn.start(queue: .global())
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, let raw = String(data: data, encoding: .utf8) else { conn.cancel(); return }
            let line = raw.components(separatedBy: "\r\n").first ?? ""
            let parts = line.split(separator: " ")
            guard parts.count >= 2, parts[0] == "GET", let drops = Storage.shared.dropsDir else {
                self.http(conn, code: 400, body: "bad request")
                return
            }
            // URL-decoded path: /<filename>
            var path = String(parts[1])
            if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
            path = path.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? path
            let name = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let file = drops.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: file.path) else {
                self.http(conn, code: 404, body: "not found")
                return
            }
            guard let body = try? Data(contentsOf: file) else {
                self.http(conn, code: 500, body: "read error")
                return
            }
            var head = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=\"\(name)\"\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            var response = Data(head.utf8)
            response.append(body)
            conn.send(content: response, completion: .contentProcessed { _ in conn.cancel() })
        }
    }

    private func http(_ conn: NWConnection, code: Int, body: String) {
        let msg = "HTTP/1.1 \(code) \(code == 200 ? "OK" : "Error")\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n\(body)"
        conn.send(content: Data(msg.utf8), completion: .contentProcessed { _ in conn.cancel() })
    }

    /// A share link for a given filename served over LAN. Returns nil if not running.
    func link(for name: String) -> String? {
        guard isRunning, let ip = localIP() else { return nil }
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        return "http://\(ip):8420/\(encoded)"
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

// MARK: - Lock Screen Widget Overlay (idle-triggered, like Droppy lock screen)

final class LockScreenController {
    static let shared = LockScreenController()
    var enabled = UserDefaults.standard.bool(forKey: "lockScreen.enabled") { didSet { UserDefaults.standard.set(enabled, forKey: "lockScreen.enabled") } }
    var idleMinutes = UserDefaults.standard.integer(forKey: "lockScreen.idleMinutes") == 0 ? 5 : UserDefaults.standard.integer(forKey: "lockScreen.idleMinutes")
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
            let droplets = DropletManager.shared.droplets
            for d in droplets {
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
        LockScreenController.shared.startMonitoring()
        ShelfCloud.shared.start { [weak self] in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.popoverVC.refreshCloudStateSafe()
            }
        }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.timerManager.tick()
            self?.popoverVC.updateClipCount(self?.clipboard.items.count ?? 0)
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
    var cloudLinkBtn: NSButton!
    var cloudStatusLabel: NSTextField!
    var cloudToggleButton: NSButton!
    var lockScreenToggle: NSButton!
    var lockScreenHint: NSTextField!

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

        // Cloud share-link button (next to Share…)
        let cloudLinkBtn = NSButton(title: "🔗 Copy LAN link", target: self, action: #selector(copyShareLink))
        cloudLinkBtn.bezelStyle = .rounded
        cloudLinkBtn.font = NSFont.systemFont(ofSize: 12)
        cloudLinkBtn.frame = NSRect(x: 120, y: 416, width: 160, height: 26)
        cloudLinkBtn.isHidden = true
        v.addSubview(cloudLinkBtn)
        self.cloudLinkBtn = cloudLinkBtn

        // Cloud status row (Settings tab)
        cloudStatusLabel = NSTextField(labelWithString: "Shelf Cloud: starting…")
        cloudStatusLabel.font = NSFont.systemFont(ofSize: 11)
        cloudStatusLabel.textColor = NSColor(white: 0.7, alpha: 1)
        cloudStatusLabel.frame = NSRect(x: 12, y: 380, width: 456, height: 16)
        cloudStatusLabel.isHidden = true
        v.addSubview(cloudStatusLabel)

        cloudToggleButton = NSButton(checkboxWithTitle: "Enable Shelf Cloud (LAN share links)", target: self, action: #selector(toggleCloud))
        cloudToggleButton.frame = NSRect(x: 12, y: 360, width: 320, height: 20)
        cloudToggleButton.isHidden = true
        v.addSubview(cloudToggleButton)

        // Lock screen widget toggle (Settings tab)
        lockScreenToggle = NSButton(checkboxWithTitle: "Show lock screen widgets when idle", target: self, action: #selector(toggleLockScreen))
        lockScreenToggle.frame = NSRect(x: 12, y: 330, width: 320, height: 20)
        lockScreenToggle.isHidden = true
        v.addSubview(lockScreenToggle)

        lockScreenHint = NSTextField(labelWithString: "Idle threshold: 5 min (set via UserDefaults lockScreen.idleMinutes)")
        lockScreenHint.font = NSFont.systemFont(ofSize: 10)
        lockScreenHint.textColor = NSColor(white: 0.6, alpha: 1)
        lockScreenHint.frame = NSRect(x: 12, y: 312, width: 456, height: 14)
        lockScreenHint.isHidden = true
        v.addSubview(lockScreenHint)

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
        cloudLinkBtn?.isHidden = currentTab != 1
        mediaRow?.isHidden = currentTab != 3
        timerAdd?.isHidden = currentTab != 2
        dropletTable.isHidden = currentTab != 4
        dropletHint.isHidden = currentTab != 4
        launchAtLogin.isHidden = currentTab != 5
        pillToggle.isHidden = currentTab != 5
        cloudStatusLabel.isHidden = currentTab != 5
        cloudToggleButton.isHidden = currentTab != 5
        lockScreenToggle.isHidden = currentTab != 5
        lockScreenHint.isHidden = currentTab != 5
        if currentTab == 5 {
            refreshPillState(UserDefaults.standard.bool(forKey: "showPill"))
            refreshCloudState()
            cloudToggleButton.state = (ShelfCloud.shared.isRunning ? .on : .off)
            lockScreenToggle.state = (LockScreenController.shared.enabled ? .on : .off)
        }
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

    @objc func copyShareLink() {
        let pick = NSOpenPanel()
        pick.canChooseFiles = true
        pick.allowsMultipleSelection = false
        pick.directoryURL = Storage.shared.dropsDir
        pick.message = "Select a file to generate a LAN share link"
        guard pick.runModal() == .OK, let url = pick.url else { return }
        guard let link = ShelfCloud.shared.link(for: url.lastPathComponent) else {
            statusLabel.stringValue = "Cloud not running — enable in Settings"
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(link, forType: .string)
        statusLabel.stringValue = "Copied: \(link)"
    }

    @objc func toggleCloud() {
        if ShelfCloud.shared.isRunning {
            ShelfCloud.shared.stop()
        } else {
            ShelfCloud.shared.start { [weak self] in
                DispatchQueue.main.async { self?.refreshCloudStateSafe() }
            }
        }
    }

    @objc func toggleLockScreen() {
        LockScreenController.shared.enabled.toggle()
        if LockScreenController.shared.enabled && !LockScreenController.shared.isShown {
            LockScreenController.shared.show()
        } else if !LockScreenController.shared.enabled {
            LockScreenController.shared.hide()
        }
    }

    func refreshCloudState() {
        if ShelfCloud.shared.isRunning {
            cloudStatusLabel.stringValue = "Shelf Cloud: ✓ running — share files via the link button in Files tab"
            cloudStatusLabel.textColor = NSColor(calibratedRed: 0.4, green: 0.9, blue: 0.4, alpha: 1)
        } else {
            cloudStatusLabel.stringValue = "Shelf Cloud: ⏸ off — toggle below to start LAN file sharing"
            cloudStatusLabel.textColor = NSColor(calibratedRed: 0.9, green: 0.5, blue: 0.3, alpha: 1)
        }
    }

    /// Calls refreshCloudState only if view is loaded. Used from async callbacks.
    func refreshCloudStateSafe() {
        if isViewLoaded { refreshCloudState() }
    }

    func updateClipCount(_ n: Int) {
        LockScreenController.shared.clipCount = n
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
