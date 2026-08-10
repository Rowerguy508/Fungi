# Shelf

An open-source macOS menu bar app inspired by [Droppy](https://getdroppy.app/). A productivity shelf in your menu bar with clipboard history, drag-drop file tray, timers, media controls, floating Dynamic Island pill, and an extensible Droplets system.

## Features

### Core
- **Clipboard manager** — text, images, files. Search, click to copy back. Persists across sessions.
- **Drag-drop file tray** — drop any file, it copies to iCloud Drive. Reveal in Finder or share via AirDrop / Messages / Mail.
- **Timers** — countdown timers with notifications.
- **Media controls** — play/pause/skip from the menu bar.
- **Launch at login** — toggleable.
- **iCloud sync** — clips, timers, dropped files all sync to iCloud Drive.

### Droplets (extension system)
Three shipped droplets, more easy to add:
- **🍅 Pomodoro** — 25 min focus / 5 min break with notifications
- **🔋 Battery monitor** — checks every 30s, alerts at 20%
- **🌤 Weather** — fetches from wttr.in (no API key needed)

Toggle droplets by double-clicking. State persists across launches.

### Floating pill
Dynamic Island-style panel at top of screen: time, clipboard count, play/pause, open-shelf button. Floats over fullscreen apps.

## Build

Requires Xcode 15+ and macOS 13+.

```bash
swift run
```

Release build:
```bash
swift build -c release
cp .build/release/Shelf /usr/local/bin/shelf
```

## Storage layout

```
~/Library/Mobile Documents/com~apple~CloudDocs/Shelf/
├── clips.json        # clipboard history
├── timers.json       # active timers
├── clipImages/       # captured image clipboard items
└── Drops/            # files dropped into the tray
```

Falls back to `~/Library/Application Support/Shelf/` if iCloud unavailable.

## Architecture

- `Storage` — iCloud-first JSON storage, automatic dir creation.
- `ClipboardManager` — polls `NSPasteboard.general` every 0.7s.
- `TimerManager` — `Timer.scheduledTimer` ticker, `UNUserNotificationCenter` for alerts.
- `MediaController` — AppleScript keystrokes for media keys.
- `DropletManager` + `Droplet` protocol — extensible droplet system.
- `DropView` — drag destination with visual feedback, copies to iCloud.
- `PillController` — `NSPanel` at `.statusBar` level, `fullScreenAuxiliary` collectionBehavior.
- `PopoverViewController` — 6 tabs: Clipboard / Files / Timers / Media / Droplets / Settings.
- `AppDelegate` — `NSStatusItem` with `NSPopover`, accessory activation policy (no dock).

## Adding your own Droplet

```swift
final class MyDroplet: Droplet {
    let id = "my-droplet"
    let name = "My Droplet"
    let icon = "✨"
    var enabled: Bool = UserDefaults.standard.bool(forKey: "droplet.my")
    private(set) var statusText = "Idle"

    func start() { /* start timers, work, etc. */ }
    func stop() { /* cleanup */ }
}
```

Then add it to `DropletManager.shared.droplets`.

## License

MIT.
