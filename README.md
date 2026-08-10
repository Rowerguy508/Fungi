# Fungi 🍄

A whimsical macOS menu bar app themed around mushrooms. Features 30 **spores** (extensions), a **nightcap** lock-screen overlay, a **basket** for tossed files (iCloud-synced), and **spore cloud** LAN sharing.

The menu bar app is the **mushroom cap**. Spores drop from it like leaves from a forest floor. All storage lives in iCloud so your fungi follows you between Macs.

## Features

### Core 🍄
- **📋 Clipboard** — text, images, files. Search, click to copy back.
- **🧺 Basket** — drag-drop files, tossed into iCloud Drive
- **⏱ Timers** — countdown with notifications
- **▶ Media** — play/pause/skip
- **🌐 iCloud sync** — clips, timers, basket all in iCloud Drive
- **🚀 Launch at login**
- **🏝 Floating pill** — Dynamic Island-style top panel

### 30 Spores (extensions)

#### Productivity (5)
- 🍅 **Pomodoro** — 25/5 cycles with notifications
- 🌱 **Truffle** — daily streak counter
- 🎋 **Bamboo** — focus session timer
- 🌳 **Morel** — random quote of the hour
- 🍀 **Clover** — todos from `~/Documents/clover.md`

#### System (8)
- 🔋 **Battery** — alerts at 20%
- 💻 **System stats** — CPU + RAM
- 📶 **Network** — SSID + ping latency
- 🌾 **Stalk** — disk usage
- 🌿 **Lichen** — system uptime
- 🦋 **Moth** — process count
- 🪨 **Capstone** — brightness
- 🌻 **Pollen** — network bytes/sec

#### Environment (3)
- 🌤 **Weather** — wttr.in, no API key
- 📅 **Calendar** — next event via EventKit
- 🌿 **Fern** — public IP via ipify

#### Activity tracking (5)
- 🌱 **Mycelium** — keys/min (CGEventTap)
- 🌿 **Pin** — keyboard shortcuts/min
- 🐝 **Bee** — most-used app today
- 🐌 **Slug** — idle duration
- 🌲 **Conifer** — deep work (no Slack/Discord)

#### Fun (4)
- 🍁 **Maple** — random hex color
- 🦊 **Fox** — current git branch
- 🐦 **Warbler** — placeholder
- 🪶 **Quill** — clipboard content hash

#### Shell (5)
- 🌐 **Frontmost URL** — Safari/Chrome tab
- 🌳 **Root** — Finder window count
- 🍄‍🟫 **Sporework** — total windows
- 🌼 **Bloom** — apps opened today
- 🍂 **Husk** — clipboard size
- 🍃 **Leaf** — run shell command periodically

### Nightcap 🌙
Idle-triggered full-screen overlay (NSPanel at `.screenSaver` level). Shows big clock, date, and live widget row (battery, weather, calendar, clip count). Hides on any input. Default 5 min idle, configurable via `nightcap.idleMinutes`.

### Spore Cloud ☁️
LAN file sharing. Serves the Basket over `http://<local IP>:8420/<filename>`. Built on `Network.framework`. Toggle from Settings.

## Storage

```
~/Library/Mobile Documents/com~apple~CloudDocs/Fungi/
├── clips.json        # clipboard history
├── timers.json       # active timers
├── clipImages/       # image clipboard items
└── Basket/           # tossed files (sync source for Spore Cloud)
```

## Build

Requires Xcode 15+, macOS 13+.

```bash
swift run                # debug build → .build/debug/Fungi
swift build -c release   # release
```

## Test results

```
[1] App start: OK
[2] iCloud Basket/ exists: True
[3] Test file dropped: True
[4] Spore Cloud port 8420: OK (reachable)
[5] HTTP GET serves file: OK (2500 bytes, matches: True)
[6] HTTP GET 404: OK (code=404)
```

## Adding your own Spore

```swift
final class MySpore: Spore {
    let id = "my"
    let name = "My Spore"
    let icon = "✨"
    var enabled: Bool = UserDefaults.standard.bool(forKey: "spore.my")
    private(set) var statusText = "Idle"
    func start() { /* work */ }
    func stop() { /* cleanup */ }
}
```

Add to `SporeManager.shared.spores` array in `main.swift`.

## License

MIT.