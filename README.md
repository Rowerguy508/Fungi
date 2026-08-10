# Shelf

Open-source macOS menu bar app inspired by [Droppy](https://getdroppy.app/). A productivity shelf in your menu bar with clipboard history, drag-drop file tray, timers, media controls, floating Dynamic Island pill, extensible Droplets, lock screen widgets, and Shelf Cloud (LAN share links).

## Features

### Core
- **Clipboard manager** — text, images, files. Search, click to copy back.
- **Drag-drop file tray** — drop files to copy them to iCloud Drive.
- **Share sheet** — AirDrop / Messages / Mail / Finder.
- **Timers** — countdown with notifications.
- **Media controls** — play/pause/skip.
- **iCloud sync** — clips, timers, files all in iCloud Drive.
- **Launch at login**.
- **Floating Dynamic Island pill** — time, clip count, play/pause.

### Droplets (extension system, 7 shipped)
- 🍅 **Pomodoro** — 25/5 min cycles with notifications
- 🔋 **Battery monitor** — alerts at 20%
- 🌤 **Weather** — wttr.in, no API key needed
- 📅 **Calendar** — next upcoming event (EventKit)
- 🌐 **Frontmost URL** — tracks Safari/Chrome tab via AppleScript
- 💻 **System stats** — CPU + RAM via sysctl + host_statistics64
- 📶 **Network** — SSID + ping latency

### Lock Screen widget overlay
- Idle-triggered full-screen panel at `.screenSaver` level
- Big clock, date, and live widget row (battery, weather, calendar, clip count)
- Configurable idle threshold (default 5 min)
- Hides on mouse movement or click

### Shelf Cloud (Droppy Cloud equivalent)
- TCP server on port 8420 using `Network.framework`
- Serves files from your iCloud `Drops/` over LAN
- "Copy LAN link" button generates `http://<local IP>:8420/<filename>`
- Toggle on/off from Settings

## Storage

```
~/Library/Mobile Documents/com~apple~CloudDocs/Shelf/
├── clips.json        # clipboard history
├── timers.json       # active timers
├── clipImages/       # image clipboard items
└── Drops/            # files dropped into tray (sync source for Shelf Cloud)
```

## Build

Requires Xcode 15+, macOS 13+.

```bash
swift run                              # debug
swift build -c release                 # release
```

## Adding a Droplet

```swift
final class MyDroplet: Droplet {
    let id = "my-droplet"
    let name = "My Droplet"
    let icon = "✨"
    var enabled: Bool = UserDefaults.standard.bool(forKey: "droplet.my")
    private(set) var statusText = "Idle"
    func start() { /* work */ }
    func stop() { /* cleanup */ }
}
```

Add to `DropletManager.shared.droplets` array.

## Test results (v4)

```
[1] App start: OK
[2] iCloud Drops/ exists: True
[3] Test file dropped: True
[4] Shelf Cloud port 8420: OK (reachable)
[5] HTTP GET serves file: OK (2500 bytes, matches: True)
[6] HTTP GET 404: OK (code=404)
```

## License

MIT.
