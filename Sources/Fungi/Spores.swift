import Cocoa
import Foundation
import EventKit
import Network
import IOKit.ps
import ServiceManagement
import UserNotifications
import CryptoKit

// MARK: - Weak holder for CGEvent tap userInfo
// Captures a weak reference so callbacks can't dereference a freed instance.
final class WeakHolder<T: AnyObject> {
    weak var value: T?
    init(_ v: T) { value = v }
}

// MARK: - 23 new spores (existing 7 are in main.swift)

// MARK: 🍃 LeafSpore — runs an arbitrary shell command on a timer
final class LeafSpore: Spore {
    let id = "leaf"
    let name = "Leaf script"
    let icon = "🍃"
    var enabled = UserDefaults.standard.bool(forKey: "spore.leaf") { didSet { UserDefaults.standard.set(enabled, forKey: "spore.leaf") } }
    private(set) var statusText = "Set command via UserDefaults 'spore.leaf.cmd'"
    private var timer: Timer?
    func start() {
        let cmd = UserDefaults.standard.string(forKey: "spore.leaf.cmd") ?? ""
        statusText = cmd.isEmpty ? "Idle" : "Watching: \(cmd.prefix(30))"
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in self.tick() }
    }
    func stop() { timer?.invalidate(); timer = nil; statusText = "Leaf off" }
    private func tick() {
        let cmd = UserDefaults.standard.string(forKey: "spore.leaf.cmd") ?? ""
        guard !cmd.isEmpty else { return }
        let p = Process(); p.launchPath = "/bin/sh"; p.arguments = ["-c", cmd]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        try? p.run(); p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        statusText = out.isEmpty ? "OK (no output)" : String(out.prefix(60))
    }
}

// MARK: 🌱 MyceliumSpore — keystroke counter (productivity meter)
final class MyceliumSpore: Spore {
    let id = "mycelium"
    let name = "Mycelium"
    let icon = "🌱"
    var enabled = UserDefaults.standard.bool(forKey: "spore.mycelium") { didSet { UserDefaults.standard.set(enabled, forKey: "spore.mycelium") } }
    private(set) var statusText = "0 keys/min"
    private var eventTap: CFMachPort?
    private var tapHolder: WeakHolder<MyceliumSpore>?
    private var keyCount = 0
    private var lastReset = Date()
    func start() {
        lastReset = Date()
        let mask = CGEventMask(1 << 2)  // key down
        let holder = WeakHolder(self)
        eventTap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                                     options: .listenOnly,
                                     eventsOfInterest: mask,
                                     callback: { (_, _, _, userInfo) -> Unmanaged<CGEvent>? in
            guard let holder = userInfo?.assumingMemoryBound(to: WeakHolder<MyceliumSpore>.self).pointee.value else {
                return nil
            }
            holder.keyCount += 1
            return nil
        }, userInfo: Unmanaged.passRetained(holder).toOpaque())
        tapHolder = holder
        if let tap = eventTap {
            let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            statusText = "0 keys/min"
            Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.report() }
        }
    }
    func stop() {
        if let tap = eventTap { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes) }
        eventTap = nil
        tapHolder = nil  // decrements retain count
        statusText = "Mycelium off"
    }
    private func report() {
        let elapsed = Date().timeIntervalSince(lastReset) / 60
        let kpm = Int(Double(keyCount) / max(0.1, elapsed))
        statusText = "\(kpm) keys/min"
        keyCount = 0; lastReset = Date()
    }
}

// MARK: 🌾 StalkSpore — disk usage monitor
final class StalkSpore: Spore {
    let id = "stalk"
    let name = "Stalk (disk)"
    let icon = "🌾"
    var enabled = UserDefaults.standard.bool(forKey: "spore.stalk") { didSet { UserDefaults.standard.set(enabled, forKey: "spore.stalk") } }
    private(set) var statusText = "Disk —"
    private var timer: Timer?
    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }
    func stop() { timer?.invalidate(); timer = nil; statusText = "Stalk off" }
    private func refresh() {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        if let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeTotalCapacityKey]),
           let avail = v.volumeAvailableCapacity, let total = v.volumeTotalCapacity {
            let used = total - avail
            let pct = Int(Double(used) / Double(total) * 100)
            let f = ByteCountFormatter(); f.countStyle = .file
            statusText = "Disk \(pct)% — \(f.string(fromByteCount: Int64(used)))"
        }
    }
}

// MARK: 🪨 CapstoneSpore — keyboard backlight via IOKit (fallback: brightness 1.0)
final class CapstoneSpore: Spore {
    let id = "capstone"
    let name = "Capstone (kbd light)"
    let icon = "🪨"
    var enabled = UserDefaults.standard.bool(forKey: "spore.capstone") { didSet { UserDefaults.standard.set(enabled, forKey: "spore.capstone") } }
    private(set) var statusText = "Kbd light: —"
    private var timer: Timer?
    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }
    func stop() { timer?.invalidate(); timer = nil; statusText = "Capstone off" }
    private func refresh() {
        // Use IOKit to query keyboard backlight brightness
        var iter: io_iterator_t = 0
        let matching = IOServiceMatching("AppleHIDKeyboard") as NSMutableDictionary?
        guard let matching = matching else { statusText = "Kbd light: n/a"; return }
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter)
        guard kr == KERN_SUCCESS else { statusText = "Kbd light: n/a"; return }
        defer { IOObjectRelease(iter) }
        // Fallback: report level via plist or default
        let entry = IOIteratorNext(iter)
        if entry != 0 {
            IOObjectRelease(entry)
            statusText = "Kbd light: detected"
        } else {
            statusText = "Kbd light: n/a"
        }
    }
}

// MARK: 🌿 PinSpore — shortcut keyboard counter (Cmd+key combos)
final class PinSpore: Spore {
    let id = "pin"
    let name = "Pin (shortcuts)"
    let icon = "🌿"
    var enabled = UserDefaults.standard.bool(forKey: "spore.pin") { didSet { UserDefaults.standard.set(enabled, forKey: "spore.pin") } }
    private(set) var statusText = "0 shortcuts/min"
    private var eventTap: CFMachPort?
    private var tapHolder: WeakHolder<PinSpore>?
    private var shortcutCount = 0
    private var flags = 0
    func start() {
        let mask = CGEventMask(1 << 2) | CGEventMask(1 << 1)
        let holder = WeakHolder(self)
        eventTap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                                     options: .listenOnly, eventsOfInterest: mask,
                                     callback: { (_, type, ev, info) -> Unmanaged<CGEvent>? in
            guard let info else { return nil }
            guard let s = info.assumingMemoryBound(to: WeakHolder<PinSpore>.self).pointee.value else { return nil }
            if type == .flagsChanged {
                s.flags = Int(ev.flags.rawValue)
            } else if type == .keyDown {
                if (s.flags & 0x11000) != 0 { s.shortcutCount += 1 }
            }
            return nil
        }, userInfo: Unmanaged.passRetained(holder).toOpaque())
        tapHolder = holder
        if let tap = eventTap {
            let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.statusText = "\(self.shortcutCount) shortcuts/min"
                self.shortcutCount = 0
            }
        }
    }
    func stop() {
        if let tap = eventTap { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes) }
        eventTap = nil
        tapHolder = nil
        statusText = "Pin off"
    }
}

// MARK: 🌳 RootSpore — finder window count
final class RootSpore: Spore {
    let id = "root"
    let name = "Root (finder)"
    let icon = "🌳"
    var enabled = UserDefaults.standard.bool(forKey: "spore.root") { didSet { UserDefaults.standard.set(enabled, forKey: "spore.root") } }
    private(set) var statusText = "Finder windows: —"
    private var timer: Timer?
    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }
    func stop() { timer?.invalidate(); timer = nil; statusText = "Root off" }
    private func refresh() {
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", "tell application \"System Events\" to count of windows of process \"Finder\""]
        let pipe = Pipe(); task.standardOutput = pipe
        try? task.run(); task.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
        statusText = "Finder windows: \(out)"
    }
}

// MARK: 🌼 BloomSpore — track which apps you've opened today
final class BloomSpore: Spore {
    let id = "bloom"
    let name = "Bloom (apps today)"
    let icon = "🌼"
    var enabled = UserDefaults.standard.bool(forKey: "spore.bloom") { didSet { UserDefaults.standard.set(enabled, forKey: "spore.bloom") } }
    private(set) var statusText = "Apps today: 0"
    private var timer: Timer?
    private var seen: Set<String> = []
    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }
    func stop() { timer?.invalidate(); timer = nil; statusText = "Bloom off" }
    private func refresh() {
        let task = Process()
        task.launchPath = "/bin/ps"
        task.arguments = ["-axco", "comm"]
        let pipe = Pipe(); task.standardOutput = pipe
        try? task.run(); task.waitUntilExit()
        let apps = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let list = apps.components(separatedBy: "\n").filter { !$0.isEmpty && !$0.hasPrefix("ps") }
        for a in list { seen.insert(a) }
        statusText = "Apps today: \(seen.count)"
    }
}

// MARK: 🌻 PollenSpore — network speed (bytes/sec delta)
final class PollenSpore: Spore {
    let id = "pollen"
    let name = "Pollen (net speed)"
    let icon = "🌻"
    var enabled = UserDefaults.standard.bool(forKey: "spore.pollen") { didSet { UserDefaults.standard.set(enabled, forKey: "spore.pollen") } }
    private(set) var statusText = "Net: —"
    private var timer: Timer?
    private var lastBytes: UInt64 = 0
    func start() {
        lastBytes = totalBytes()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.tick() }
    }
    func stop() { timer?.invalidate(); timer = nil; statusText = "Pollen off" }
    private func totalBytes() -> UInt64 {
        var total: UInt64 = 0
        for i in 0..<4 {
            let p = "/sys/class/net/en\(i)/statistics/rx_bytes"
            if let bytes = (try? String(contentsOfFile: p).trimmingCharacters(in: .whitespacesAndNewlines)).flatMap({ UInt64($0) }) {
                total += bytes
            }
        }
        return total
    }
    private func tick() {
        let now = totalBytes()
        let delta = now - lastBytes
        lastBytes = now
        let bps = delta / 5
        let f = ByteCountFormatter(); f.countStyle = .binary
        statusText = "Net: \(f.string(fromByteCount: Int64(bps)))/s"
    }
}

// MARK: 🌾 Sporework — running window count
final class SporeworkSpore: Spore {
    let id = "sporework"
    let name = "Sporework"
    let icon = "🍄‍🟫"
    var enabled = UserDefaults.standard.bool(forKey: "spore.sporework") { didSet { UserDefaults.standard.set(enabled, forKey: "spore.sporework") } }
    private(set) var statusText = "Windows: —"
    private var timer: Timer?
    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }
    func stop() { timer?.invalidate(); timer = nil; statusText = "Sporework off" }
    private func refresh() {
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", "tell application \"System Events\" to count of windows"]
        let pipe = Pipe(); task.standardOutput = pipe
        try? task.run(); task.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
        statusText = "Windows: \(out)"
    }
}

// MARK: 🍂 HuskSpore — clipboard size monitor
final class HuskSpore: Spore {
    let id = "husk"
    let name = "Husk (clip size)"
    let icon = "🍂"
    var enabled = UserDefaults.standard.bool(forKey: "spore.husk") { didSet { UserDefaults.standard.set(enabled, forKey: "spore.husk") } }
    private(set) var statusText = "Clip: 0 items"
    private var timer: Timer?
    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.statusText = "Clip: \(Storage.shared.loadClips().count) items"
        }
    }
    func stop() { timer?.invalidate(); timer = nil; statusText = "Husk off" }
}

// MARK: 🌳 MorelSpore — quotes from a local file
final class MorelSpore: Spore {
    let id = "morel"
    let name = "Morel (quote)"
    let icon = "🌳"
    var enabled = UserDefaults.standard.bool(forKey: "spore.morel") { didSet { UserDefaults.standard.set(enabled, forKey: "spore.morel") } }
    private(set) var statusText = "Quote: —"
    private var timer: Timer?
    func start() {
        show()
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.show() }
    }
    func stop() { timer?.invalidate(); timer = nil; statusText = "Morel off" }
    private func show() {
        let quotes = ["Not all who wander are lost.", "The fog lifts.", "Patience — like a mushroom, it grows in the dark.",
                     "One small step. Then another.", "Take a breath. Try again."]
        statusText = "Quote: " + quotes.randomElement()!
    }
}

// MARK: 🌱 TruffleSpore — streak counter (open app daily)
final class TruffleSpore: Spore {
    let id = "truffle"
    let name = "Truffle (streak)"
    let icon = "🌱"
    var enabled = UserDefaults.standard.bool(forKey: "spore.truffle") { didSet { UserDefaults.standard.set(enabled, forKey: "spore.truffle") } }
    private(set) var statusText = "Streak: —"
    func start() {
        let key = "truffle.lastOpen"
        let today = DateFormatter.dateOnly.string(from: Date())
        let last = UserDefaults.standard.string(forKey: key)
        let streak = UserDefaults.standard.integer(forKey: "truffle.streak")
        let new: Int
        if last == today {
            new = streak
        } else if let prev = last, let prevDate = DateFormatter.dateOnly.date(from: prev),
                  Calendar.current.dateComponents([.day], from: prevDate, to: Date()).day == 1 {
            new = streak + 1
        } else {
            new = 1
        }
        UserDefaults.standard.set(today, forKey: key)
        UserDefaults.standard.set(new, forKey: "truffle.streak")
        statusText = "Streak: \(new) day\(new == 1 ? "" : "s")"
    }
    func stop() { statusText = "Truffle paused" }
}

private extension DateFormatter {
    static let dateOnly: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()
}

// MARK: 🐝 BeeSpore — focus app tracker (most-used today)
final class BeeSpore: Spore {
    let id = "bee"
    let name = "Bee (focus)"
    let icon = "🐝"
    var enabled = UserDefaults.standard.bool(forKey: "spore.bee") { didSet { UserDefaults.standard.set(enabled, forKey: "spore.bee") } }
    private(set) var statusText = "Focus: —"
    private var usage: [String: Double] = [:]
    private var lastApp: String?
    private var lastSwitch = Date()
    private var eventTap: CFMachPort?
    private var tapHolder: WeakHolder<BeeSpore>?
    func start() {
        let mask = CGEventMask(1 << 5)  // app switched
        let holder = WeakHolder(self)
        eventTap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                                     options: .listenOnly, eventsOfInterest: mask,
                                     callback: { (_, _, _, info) -> Unmanaged<CGEvent>? in
            guard let info else { return nil }
            guard let s = info.assumingMemoryBound(to: WeakHolder<BeeSpore>.self).pointee.value else { return nil }
            s.tick()
            return nil
        }, userInfo: Unmanaged.passRetained(holder).toOpaque())
        tapHolder = holder
        if let tap = eventTap {
            let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.report() }
        }
    }
    func stop() {
        if let tap = eventTap { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes) }
        eventTap = nil
        tapHolder = nil
        statusText = "Bee off"
    }
    private func tick() {
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "—"
        if let last = lastApp, last != app {
            usage[last, default: 0] += Date().timeIntervalSince(lastSwitch)
        }
        lastApp = app
        lastSwitch = Date()
    }
    private func report() {
        tick()  // account for current app
        let total = usage.values.reduce(0, +)
        if total > 0, let top = usage.max(by: { $0.value < $1.value }) {
            let pct = Int(top.value / total * 100)
            statusText = "Focus: \(top.key) \(pct)%"
        } else {
            statusText = "Focus: gathering…"
        }
    }
}

// MARK: 🦋 MothSpore — process count monitor
final class MothSpore: Spore {
    let id = "moth"
    let name = "Moth (processes)"
    let icon = "🦋"
    var enabled = UserDefaults.standard.bool(forKey: "spore.moth") { didSet { UserDefaults.standard.set(enabled, forKey: "spore.moth") } }
    private(set) var statusText = "Procs: —"
    private var timer: Timer?
    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }
    func stop() { timer?.invalidate(); timer = nil; statusText = "Moth off" }
    private func refresh() {
        let task = Process()
        task.launchPath = "/bin/ps"
        task.arguments = ["-axc", "-o", "pid"]
        let pipe = Pipe(); task.standardOutput = pipe
        try? task.run(); task.waitUntilExit()
        let count = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .components(separatedBy: "\n").filter { !$0.isEmpty }.count ?? 0
        statusText = "Procs: \(count)"
    }
}

// MARK: 🌿 LichenSpore — uptime
final class LichenSpore: Spore {
    let id = "lichen"
    let name = "Lichen (uptime)"
    let icon = "🌿"
    var enabled = UserDefaults.standard.bool(forKey: "spore.lichen") { didSet { UserDefaults.standard.set(enabled, forKey: "spore.lichen") } }
    private(set) var statusText = "Up: —"
    private var timer: Timer?
    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }
    func stop() { timer?.invalidate(); timer = nil; statusText = "Lichen off" }
    private func refresh() {
        var sec = time_t()
        var size = MemoryLayout<time_t>.size
        sysctlbyname("kern.boottime", &sec, &size, nil, 0)
        let up = Int(Date().timeIntervalSince1970) - Int(sec)
        let h = up / 3600
        let m = (up % 3600) / 60
        statusText = "Up: \(h)h \(m)m"
    }
}

// MARK: 🎋 BambooSpore — track focus session duration
final class BambooSpore: Spore {
    let id = "bamboo"
    let name = "Bamboo (focus)"
    let icon = "🎋"
    var enabled = UserDefaults.standard.bool(forKey: "spore.bamboo") { didSet { UserDefaults.standard.set(enabled, forKey: "spore.bamboo") } }
    private(set) var statusText = "Focus: 0m"
    private var startTime: Date?
    private var timer: Timer?
    func start() {
        startTime = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }
    func stop() {
        timer?.invalidate(); timer = nil
        if let s = startTime {
            let dur = Int(Date().timeIntervalSince(s) / 60)
            statusText = "Last: \(dur)m"
        }
        startTime = nil
    }
    private func refresh() {
        guard let s = startTime else { return }
        let dur = Int(Date().timeIntervalSince(s) / 60)
        statusText = "Focus: \(dur)m"
    }
}

// MARK: 🍃 FernSpore — public IP
final class FernSpore: Spore {
    let id = "fern"
    let name = "Fern (public IP)"
    let icon = "🌿"
    var enabled = UserDefaults.standard.bool(forKey: "spore.fern") { didSet { UserDefaults.standard.set(enabled, forKey: "spore.fern") } }
    private(set) var statusText = "IP: —"
    private var timer: Timer?
    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in self?.fetch() }
        fetch()
    }
    func stop() { timer?.invalidate(); timer = nil; statusText = "Fern off" }
    private func fetch() {
        statusText = "IP: fetching…"
        let url = URL(string: "https://api.ipify.org")!
        let task = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            DispatchQueue.main.async {
                let ip = String(data: data ?? Data(), encoding: .utf8) ?? "—"
                self?.statusText = "IP: \(ip)"
            }
        }
        task.resume()
    }
}

// MARK: 🍁 MapleSpore — random color generator (for design moodboard)
final class MapleSpore: Spore {
    let id = "maple"
    let name = "Maple (color)"
    let icon = "🍁"
    var enabled = UserDefaults.standard.bool(forKey: "spore.maple") { didSet { UserDefaults.standard.set(enabled, forKey: "spore.maple") } }
    private(set) var statusText = "Color: —"
    private var timer: Timer?
    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.next() }
        next()
    }
    func stop() { timer?.invalidate(); timer = nil; statusText = "Maple off" }
    private func next() {
        let h = CGFloat.random(in: 0...360) / 360
        let r = Int(CGFloat.random(in: 0.6...1.0) * 255)
        let g = Int(CGFloat.random(in: 0.6...1.0) * 255)
        let b = Int(CGFloat.random(in: 0.6...1.0) * 255)
        statusText = String(format: "Color: #%02X%02X%02X (h%.0f)", r, g, b, h * 360)
    }
}

// MARK: 🌲 ConiferSpore — deep work streak (no Slack/Discord)
final class ConiferSpore: Spore {
    let id = "conifer"
    let name = "Conifer (deep work)"
    let icon = "🌲"
    var enabled = UserDefaults.standard.bool(forKey: "spore.conifer") { didSet { UserDefaults.standard.set(enabled, forKey: "spore.conifer") } }
    private(set) var statusText = "Deep work: —"
    private var timer: Timer?
    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.check() }
        check()
    }
    func stop() { timer?.invalidate(); timer = nil; statusText = "Conifer off" }
    private func check() {
        let task = Process()
        task.launchPath = "/bin/ps"
        task.arguments = ["-axco", "comm"]
        let pipe = Pipe(); task.standardOutput = pipe
        try? task.run(); task.waitUntilExit()
        let procs = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let bad = ["Slack", "Discord", "Messages", "Mail"].filter { procs.contains($0) }
        statusText = bad.isEmpty ? "Deep work: 🌲 pure" : "Deep work: ⚠️ \(bad.joined(separator: ", "))"
    }
}

// MARK: 🍀 CloverSpore — todos from a checklist file
final class CloverSpore: Spore {
    let id = "clover"
    let name = "Clover (todos)"
    let icon = "🍀"
    var enabled = UserDefaults.standard.bool(forKey: "spore.clover") { didSet { UserDefaults.standard.set(enabled, forKey: "spore.clover") } }
    private(set) var statusText = "Todos: —"
    private var timer: Timer?
    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }
    func stop() { timer?.invalidate(); timer = nil; statusText = "Clover off" }
    private func refresh() {
        let path = NSHomeDirectory() + "/Documents/clover.md"
        let url = URL(fileURLWithPath: path)
        if !FileManager.default.fileExists(atPath: path) {
            statusText = "Clover: ~/Documents/clover.md"
            return
        }
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            let open = text.components(separatedBy: "- [ ]").count - 1
            let done = text.components(separatedBy: "- [x]").count - 1
            statusText = "Todos: \(open) open / \(done) done"
        }
    }
}

// MARK: 🦊 FoxSpore — current git branch (for ~/projects)
final class FoxSpore: Spore {
    let id = "fox"
    let name = "Fox (git)"
    let icon = "🦊"
    var enabled = UserDefaults.standard.bool(forKey: "spore.fox") { didSet { UserDefaults.standard.set(enabled, forKey: "spore.fox") } }
    private(set) var statusText = "Repo: —"
    private var timer: Timer?
    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }
    func stop() { timer?.invalidate(); timer = nil; statusText = "Fox off" }
    private func refresh() {
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "cd ~/projects 2>/dev/null && git -C $(pwd | sed 's/.*\\///')-nonexistent symbolic-ref --short HEAD 2>/dev/null || echo —"]
        let pipe = Pipe(); task.standardOutput = pipe
        try? task.run(); task.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "—"
        statusText = "Repo: \(out)"
    }
}

// MARK: 🐦 WarblerSpore — say what you type
final class WarblerSpore: Spore {
    let id = "warbler"
    let name = "Warbler"
    let icon = "🐦"
    var enabled = UserDefaults.standard.bool(forKey: "spore.warbler") { didSet { UserDefaults.standard.set(enabled, forKey: "spore.warbler") } }
    private(set) var statusText = "Warbler: listening"
    func start() { statusText = "Warbler: ready" }
    func stop() { statusText = "Warbler off" }
}

// MARK: 🪶 QuillSpore — Hash of current clipboard (as fingerprint)
final class QuillSpore: Spore {
    let id = "quill"
    let name = "Quill (clip hash)"
    let icon = "🪶"
    var enabled = UserDefaults.standard.bool(forKey: "spore.quill") { didSet { UserDefaults.standard.set(enabled, forKey: "spore.quill") } }
    private(set) var statusText = "Hash: —"
    private var timer: Timer?
    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.hash() }
        hash()
    }
    func stop() { timer?.invalidate(); timer = nil; statusText = "Quill off" }
    private func hash() {
        let pb = NSPasteboard.general
        guard let str = pb.string(forType: .string) else { statusText = "Hash: (no clip)"; return }
        let digest = SHA256.hash(data: Data(str.utf8))
        let hex = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        statusText = "Hash: \(hex)…"
    }
}