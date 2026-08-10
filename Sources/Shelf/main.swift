import Cocoa
import Foundation
import Combine
import AppKit
import UserNotifications
import ServiceManagement
import AVFoundation
import MediaPlayer
import Security

// MARK: - Models

struct ClipboardItem: Identifiable, Codable, Equatable {
    let id: UUID
    let timestamp: Date
    let text: String?
    let imagePath: String?  // Relative to support dir
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

// MARK: - Storage

final class Storage {
    static let shared = Storage()
    let supportDir: URL
    let clipsFile: URL
    let timersFile: URL
    let imagesDir: URL

    private init() {
        let fm = FileManager.default
        let base = try! fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        supportDir = base.appendingPathComponent("Shelf", isDirectory: true)
        try? fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
        imagesDir = supportDir.appendingPathComponent("clipImages", isDirectory: true)
        try? fm.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        clipsFile = supportDir.appendingPathComponent("clips.json")
        timersFile = supportDir.appendingPathComponent("timers.json")
    }

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
        case .play: script = "tell application \"System Events\" to keystroke (ASCII character 16) using {command down}"
        case .pause: script = "tell application \"System Events\" to keystroke (ASCII character 16) using {command down}"
        case .next: script = "tell application \"System Events\" to key code 124 using {command down, option down}"
        case .previous: script = "tell application \"System Events\" to key code 123 using {command down, option down}"
        case .toggle: script = "tell application \"System Events\" to keystroke (ASCII character 16) using {command down}"
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
        let n = NSUserNotification()
        n.title = "Timer done"
        n.informativeText = label
        NSUserNotificationCenter.default.deliver(n)
    }
    private func requestNotifPerm() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}

// MARK: - App Delegate (Menu Bar)

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    let statusBar = NSStatusBar.system
    let menu = NSMenu()
    let popover = NSPopover()
    let popoverVC = PopoverViewController()
    let clipboard = ClipboardManager()
    let timerManager = TimerManager()
    var tickTimer: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = statusBar.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "◰"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        // Popover content
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 460, height: 580)
        popover.contentViewController = popoverVC
        popoverVC.clipboard = clipboard
        popoverVC.timerManager = timerManager
        popoverVC.media = MediaController.self
        // Start services
        clipboard.start()
        timerManager.start()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.timerManager.tick()
        }
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
    var media: MediaController.Type!
    let tabs = ["Clipboard", "Files", "Timers", "Media", "Settings"]
    var currentTab = 0
    var tabButtons: [NSButton] = []
    let stack = NSStackView()
    let searchField = NSTextField()
    let clipTable = NSTableView()
    let fileList = NSTableView()
    let timerList = NSTableView()
    var timerLabelField: NSTextField!
    var timerMinutesField: NSTextField!
    var statusLabel: NSTextField!
    var launchAtLogin: NSButton!

    override func loadView() {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 580))
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 1.0).cgColor

        // Header
        let header = NSView(frame: NSRect(x: 0, y: 540, width: 460, height: 40))
        header.wantsLayer = true
        header.layer?.backgroundColor = NSColor(calibratedWhite: 0.16, alpha: 1.0).cgColor
        v.addSubview(header)

        let title = NSTextField(labelWithString: "Shelf")
        title.font = NSFont.systemFont(ofSize: 16, weight: .bold)
        title.textColor = .white
        title.frame = NSRect(x: 16, y: 10, width: 200, height: 22)
        header.addSubview(title)

        // Tabs
        let tabStack = NSStackView()
        tabStack.orientation = .horizontal
        tabStack.distribution = .fillEqually
        tabStack.spacing = 0
        tabStack.frame = NSRect(x: 0, y: 500, width: 460, height: 36)
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
        searchField.frame = NSRect(x: 12, y: 466, width: 436, height: 26)
        searchField.bezelStyle = .roundedBezel
        v.addSubview(searchField)

        // Table
        configureTable(clipTable)
        configureTable(fileList)
        configureTable(timerList)
        stack.addArrangedSubview(clipTable)
        stack.addArrangedSubview(fileList)
        stack.addArrangedSubview(timerList)
        stack.frame = NSRect(x: 0, y: 60, width: 460, height: 400)
        stack.orientation = .vertical
        v.addSubview(stack)
        clipTable.isHidden = false
        fileList.isHidden = true
        timerList.isHidden = true

        // Media buttons row
        let mediaRow = NSStackView()
        mediaRow.orientation = .horizontal
        mediaRow.distribution = .fillEqually
        mediaRow.spacing = 8
        mediaRow.frame = NSRect(x: 12, y: 60, width: 436, height: 40)
        for (label, cmd) in [("⏮", MediaCommand.previous), ("⏯", MediaCommand.toggle), ("⏭", MediaCommand.next)] {
            let b = NSButton(title: label, target: self, action: #selector(mediaButton(_:)))
            b.tag = ["previous", "toggle", "next"].firstIndex(of: cmd.rawValue) ?? 0
            b.bezelStyle = .rounded
            b.font = NSFont.systemFont(ofSize: 18)
            mediaRow.addArrangedSubview(b)
        }
        mediaRow.isHidden = true
        v.addSubview(mediaRow)
        stack.addArrangedSubview(mediaRow)
        self.mediaRow = mediaRow

        // Timer add row
        let timerAdd = NSStackView()
        timerAdd.orientation = .horizontal
        timerAdd.spacing = 6
        timerAdd.frame = NSRect(x: 12, y: 12, width: 436, height: 40)
        timerLabelField = NSTextField(string: "")
        timerLabelField.placeholderString = "Label"
        timerLabelField.bezelStyle = .roundedBezel
        timerLabelField.frame = NSRect(x: 0, y: 8, width: 140, height: 24)
        timerMinutesField = NSTextField(string: "25")
        timerMinutesField.bezelStyle = .roundedBezel
        timerMinutesField.frame = NSRect(x: 150, y: 8, width: 60, height: 24)
        let addBtn = NSButton(title: "Add Timer", target: self, action: #selector(addTimer))
        addBtn.bezelStyle = .rounded
        addBtn.frame = NSRect(x: 220, y: 8, width: 100, height: 24)
        timerAdd.addArrangedSubview(timerLabelField)
        timerAdd.addArrangedSubview(timerMinutesField)
        timerAdd.addArrangedSubview(addBtn)
        timerAdd.isHidden = true
        v.addSubview(timerAdd)
        self.timerAdd = timerAdd

        // Settings row
        launchAtLogin = NSButton(checkboxWithTitle: "Launch Shelf at login", target: self, action: #selector(toggleLaunchAtLogin))
        launchAtLogin.frame = NSRect(x: 16, y: 16, width: 300, height: 22)
        launchAtLogin.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        launchAtLogin.isHidden = true
        v.addSubview(launchAtLogin)
        self.launchAtLoginRef = launchAtLogin

        // Footer status
        statusLabel = NSTextField(labelWithString: "Ready")
        statusLabel.textColor = NSColor(white: 0.6, alpha: 1)
        statusLabel.font = NSFont.systemFont(ofSize: 10)
        statusLabel.frame = NSRect(x: 12, y: 0, width: 436, height: 14)
        v.addSubview(statusLabel)

        self.view = v
    }

    var mediaRow: NSStackView!
    var timerAdd: NSStackView!
    var launchAtLoginRef: NSButton!

    override func viewDidAppear() {
        super.viewDidAppear()
        clipTable.reloadData()
    }

    private func configureTable(_ t: NSTableView) {
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c"))
        col.width = 440
        t.addTableColumn(col)
        t.headerView = nil
        t.dataSource = self
        t.delegate = self
        t.backgroundColor = .clear
        t.target = self
        t.doubleAction = #selector(doubleClickRow)
        t.usesAlternatingRowBackgroundColors = false
        t.rowHeight = 28
    }

    @objc func switchTab(_ sender: NSButton) {
        currentTab = sender.tag
        for (i, b) in tabButtons.enumerated() {
            b.contentTintColor = (i == currentTab) ? .white : NSColor(white: 0.6, alpha: 1)
            b.layer?.backgroundColor = (i == currentTab ? NSColor(calibratedRed: 0.2, green: 0.5, blue: 0.9, alpha: 1) : .clear).cgColor
        }
        clipTable.isHidden = currentTab != 0
        fileList.isHidden = currentTab != 1
        timerList.isHidden = currentTab != 2
        searchField.isHidden = currentTab != 0
        mediaRow?.isHidden = currentTab != 3
        timerAdd?.isHidden = currentTab != 2
        launchAtLoginRef?.isHidden = currentTab != 4
        clipTable.reloadData()
        timerList.reloadData()
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
            if launchAtLoginRef.state == .on {
                try svc.register()
            } else {
                try svc.unregister()
            }
        } catch {
            statusLabel.stringValue = "Login item error: \(error.localizedDescription)"
        }
    }

    @objc func doubleClickRow() {
        let table: NSTableView = currentTab == 0 ? clipTable : timerList
        let row = table.clickedRow
        if currentTab == 0, row >= 0, let item = clipboard?.filtered[safe: row] {
            clipboard?.copy(item)
            statusLabel.stringValue = "Copied to clipboard"
        } else if currentTab == 2, row >= 0, let timer = timerManager?.timers[safe: row] {
            timerManager?.cancel(timer.id)
            timerList.reloadData()
            statusLabel.stringValue = "Timer cancelled"
        }
    }

    // NSTableView
    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView == clipTable { return clipboard?.filtered.count ?? 0 }
        if tableView == timerList { return timerManager?.timers.count ?? 0 }
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
        } else if tableView == timerList, let t = timerManager?.timers[safe: row] {
            let remaining = max(0, t.fireDate.timeIntervalSinceNow)
            let m = Int(remaining) / 60
            let s = Int(remaining) % 60
            tf.stringValue = "\(t.label)  \(m):\(String(format: "%02d", s))"
        }
        tf.frame = NSRect(x: 8, y: 4, width: 440, height: 20)
        cell.addSubview(tf)
        cell.backgroundStyle = .dark
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
app.setActivationPolicy(.accessory)  // Menu bar only, no dock icon
app.run()
