# Fungi 🍄

A whimsical macOS menu bar app themed around mushrooms. Your Mac becomes a forest floor — the app is the mushroom cap, and 30 **spores** drop from it. Includes a **nightcap** lock-screen overlay, a **basket** for tossed files, and **spore cloud** LAN sharing.

## Fungi vocabulary

| Old name | New name | What it is |
|---|---|---|
| App | **Fungi** | The mushroom cap, lives in your menu bar |
| Main popover | **The Burrow** | Home — your fungi takes root here |
| Extensions (30) | **Toadstools** | Toggle in the Fairy Ring |
| Extension marketplace | **Fairy Ring** | Where the toadstools grow |
| File tray | **Basket** | Toss files here, iCloud-synced |
| Clipboard | **Pantry** | Every copy, kept and searchable |
| Lock screen | **Nightcap** | Idle overlay, glass + widgets |
| Cloud sharing | **Spore Cloud** | LAN file sharing |
| Floating pill | **Burrow pill** | Dynamic Island-style top panel |

## Visual style

Inspired by [getdroppy.app](https://getdroppy.app/):
- **Dark glass cards** with translucent blur
- **Sidebar nav** with accent-tinted active state
- **Fungal palette**: canopy (page), mycelium (cards), cap (primary accent), moss (success), spore (pink), gill (cream)
- **Rounded corners** (14px cards, 8-12px controls)
- **Hero emoji + tagline** on the Burrow landing tab
- **Status footer** showing last action

## Tabs

1. **Burrow** 🍄 — landing with hero + live status
2. **Pantry** 📋 — searchable clipboard history
3. **Basket** 🧺 — drag-drop files → iCloud, share via AirDrop/Mail/Spore Cloud
4. **Timers** ⏱ — countdowns with notifications
5. **Media** 🎵 — play/pause/skip with circular controls
6. **Fairy Ring** 🪄 — 30 toadstools (extensions) to toggle
7. **Settings** ⚙ — cloud, nightcap, pill, launch-at-login

## 30 toadstools

### Productivity (5)
🍅 Pomodoro · 🌱 Truffle · 🎋 Bamboo · 🌳 Morel · 🍀 Clover

### System (8)
🔋 Battery · 💻 System stats · 📶 Network · 🌾 Stalk · 🌿 Lichen · 🦋 Moth · 🪨 Capstone · 🌻 Pollen

### Environment (3)
🌤 Weather · 📅 Calendar · 🌿 Fern

### Activity (5)
🌱 Mycelium · 🌿 Pin · 🐝 Bee · 🐌 Slug · 🌲 Conifer

### Fun (4)
🍁 Maple · 🦊 Fox · 🐦 Warbler · 🪶 Quill

### Shell (5+1)
🌐 Frontmost URL · 🌳 Root · 🍄‍🟫 Sporework · 🌼 Bloom · 🍂 Husk · 🍃 Leaf

## Storage

```
~/Library/Mobile Documents/com~apple~CloudDocs/Fungi/
├── clips.json        # Pantry clipboard history
├── timers.json       # Active timers
├── clipImages/       # Captured image clipboard
└── Basket/           # Tossed files (source for Spore Cloud)
```

## Build

```bash
swift run                # debug build → .build/debug/Fungi
swift build -c release   # release
```

## Test results

```
[1] App start: OK
[2] Spore Cloud port 8420: OK (reachable)
[3] HTTP GET serves file: OK (1700 bytes)
[4] App process status after 6s: OK
```

## Adding your own Toadstool

```swift
final class MyToadstool: Spore {
    let id = "my"
    let name = "My Toadstool"
    let icon = "✨"
    var enabled: Bool = UserDefaults.standard.bool(forKey: "spore.my")
    private(set) var statusText = "Idle"
    func start() { /* work */ }
    func stop() { /* cleanup */ }
}
```

Add to `SporeManager.shared.spores` array.

## License

MIT.