# Fungi 🍄

A whimsical macOS menu bar app themed around mushrooms. Your Mac becomes a forest floor — the app is the mushroom cap, and 34 **spores** drop from it. Includes a **nightcap** lock-screen overlay, a **basket** for tossed files, **spore cloud** LAN sharing, and a full grove of tools: window snapping, screenshot markup, live lyrics, voice transcription, quick replies, a terminal, and more.

## Fungi vocabulary

| Old name | New name | What it is |
|---|---|---|
| App | **Fungi** | The mushroom cap, lives in your menu bar |
| Main popover | **The Burrow** | Home — your fungi takes root here |
| Extensions (34) | **Toadstools** | Toggle in the Fairy Ring |
| Extension marketplace | **Fairy Ring** | Where the toadstools grow |
| File tray | **Basket** | Toss files here, iCloud-synced |
| Clipboard | **Pantry** | Every copy, kept and searchable |
| Lock screen | **Nightcap** | Idle overlay, glass + widgets |
| Cloud sharing | **Spore Cloud** | LAN file sharing |
| Floating pill | **Burrow pill** | Dynamic Island-style top panel |
| Window snapping | **Trellis** | Snap the front window (halves/quarters/full) |
| Screenshot editor | **Spore Print** | Region capture → markup → copy or Basket |
| Emoji picker | **Firefly** | Floating emoji grid, click to copy |
| Volume/brightness HUD | **Glow** | Volume slider + brightness keys + mic mute |
| Audio output picker | **Breeze** | Switch default output (incl. AirPlay devices) |
| Meeting controls | **Council** | Detects Zoom/Teams/etc, one-tap mic mute |
| Live lyrics | **Songbird** | Line-synced lyrics for the Music app (lrclib) |
| Voice memos + transcription | **Echo** | Record → on-device transcription → iCloud |
| NL calendar/reminders | **Almanac** | "Lunch with Sam tomorrow 12:30" → event |
| Terminal | **Hollow** | Run shell commands from the Burrow |
| Quick replies | **Post** | Send iMessage instantly, draft WhatsApp |
| Background removal | **Peel** | AI subject cutout → Basket (macOS 14+) |
| Low Power Mode | — | Toggle from the Grove (admin prompt) |

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
5. **Media** 🎵 — play/pause/skip + 🐦 Songbird live line-synced lyrics
6. **Grove** 🌳 — Trellis snapping, Glow volume/brightness/mic, Breeze output picker, Council meeting mute, Spore Print, Firefly, Peel, Low Power Mode
7. **Post** 📮 — instant iMessage send + WhatsApp drafts
8. **Almanac** 📖 — natural-language events & reminders (EventKit)
9. **Hollow** 🪵 — zsh terminal in the Burrow
10. **Echo** 🎙 — voice recording with on-device transcription (Speech)
11. **Fairy Ring** 🪄 — 34 toadstools (extensions) to toggle
12. **Settings** ⚙ — cloud, nightcap, pill, launch-at-login

## 34 toadstools

### Productivity (5)
🍅 Pomodoro · 🌱 Truffle · 🎋 Bamboo · 🌳 Morel · 🍀 Clover

### System (9)
🔋 Battery · 💻 System stats · 📶 Network · 🌾 Stalk · 🌿 Lichen · 🦋 Moth · 🪨 Capstone · 🌻 Pollen · 🌵 Cactus

### Environment (3)
🌤 Weather · 📅 Calendar · 🌿 Fern

### Activity (5)
🌱 Mycelium · 🌿 Pin · 🐝 Bee · 🐌 Slug · 🌲 Conifer

### Fun (6)
🍁 Maple · 🦊 Fox · 🐦 Warbler · 🪶 Quill · 🦗 Cricket (key sounds) · 🦉 Familiar (Claude/Codex/aider tracking)

### Shell (6)
🌐 Frontmost URL · 🌳 Root · 🍄‍🟫 Sporework · 🌼 Bloom · 🍂 Husk · 🍃 Leaf

## Droppy feature parity

Built to match [getdroppy.app](https://getdroppy.app/)'s feature list:

| Droppy | Fungi | How |
|---|---|---|
| File shelf + cloud links | Basket + Spore Cloud | Swifter HTTP server, browsable index |
| Global hotkeys | Chimes | KeyboardShortcuts, rebindable in Settings |
| Clipboard manager | Pantry | poll + search + images/files |
| Notch/pill hub | Burrow pill | floating glass panel |
| Media player + lyrics | Media + Songbird | AppleScript + lrclib.net LRC sync |
| Lock screen widgets | Nightcap | idle overlay with widgets |
| Window snapping | Trellis | Accessibility API (AX) |
| Screenshot editor | Spore Print | `screencapture -i` + markup window |
| Emoji picker | Firefly | floating panel, copy on click |
| Volume/brightness HUDs | Glow | osascript volume, NX brightness keys |
| AirPlay/output picker | Breeze | SimplyCoreAudio, live hot-plug updates |
| Meeting controls | Council | app detection + system mic mute |
| WhatsApp/iMessage replies | Post | Messages AppleScript, wa.me deep link |
| Voice transcription | Echo | AVAudioRecorder + SFSpeechRecognizer |
| NL calendar/reminders | Almanac | NSDataDetector + EventKit |
| Terminal in notch | Hollow | zsh runner with scrollback |
| Battery alerts + Low Power | Battery spore + Grove toggle | IOKit + `pmset lowpowermode` |
| AI background removal | Peel | Vision foreground mask (macOS 14+) |
| Mechanical keyboard sounds | Cricket | global key monitor + system sounds |
| Claude/Codex progress | Familiar | pgrep + CPU sampling |

## Open source we lean on

Rather than hand-rolling these, Fungi pulls them in via SwiftPM:

| Package | License | What it replaces |
|---|---|---|
| [httpswift/swifter](https://github.com/httpswift/swifter) `1.5.0` | BSD-3-Clause | Spore Cloud's hand-written HTTP parser — now gets real routing, MIME types, range requests and streaming file serving |
| [rnine/SimplyCoreAudio](https://github.com/rnine/SimplyCoreAudio) `4.1.1` | MIT | ~60 lines of raw `AudioObjectGetPropertyData` in Breeze, plus device hot-plug notifications |
| [sindresorhus/KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) `1.10.0` | MIT | Carbon hotkey registration, persistence, and the recorder control in Settings |

Deliberately **not** pulled in:

- **LyricsKit** — it drags in five transitive dependencies (CombineX, CXExtensions, Regex, SwiftCF, GzipSwift) to do what Songbird already does in ~40 lines against [lrclib.net](https://lrclib.net). The wheel we have is smaller than the library.
- **Rectangle / Loop** for Trellis — they're apps, not libraries, and GPL-3, which would relicense this MIT project. The `AXUIElement` calls Trellis uses are the same ones they make.

## Storage

```
~/Library/Mobile Documents/com~apple~CloudDocs/Fungi/
├── clips.json        # Pantry clipboard history
├── timers.json       # Active timers
├── clipImages/       # Captured image clipboard
├── Echoes/           # Voice recordings (.m4a) + transcripts (.txt)
└── Basket/           # Tossed files, spore prints, peeled cutouts
```

## Chimes (global hotkeys)

Every one is rebindable in **Settings → Chimes**; these are just the defaults.

| Default | Action |
|---|---|
| `⌘⌥F` | Open the Burrow |
| `⌘⌥⇧4` | Spore Print (region capture → markup) |
| `⌘⌥E` | Firefly emoji picker |
| `⌘⌥⇧M` | Mute / unmute mic |
| `⌘⌥←` / `⌘⌥→` / `⌘⌥↑` | Snap window left / right / full |
| `⌘⌥⇧V` | Paste last clip from the Pantry |

Hotkeys fired while the popover is closed show a brief glass HUD near the bottom of the screen.

## Permissions

Features prompt for their system permission on first use:

- **Trellis** → Accessibility
- **Echo** → Microphone + Speech Recognition
- **Almanac** → Calendars / Reminders
- **Post (iMessage)** → Automation (Messages)
- **Cricket** → Input Monitoring
- **Low Power Mode** → administrator password (via `pmset`)

## Build

```bash
swift run                # debug build → .build/debug/Fungi
swift build -c release   # release
```

First build resolves the three SwiftPM dependencies above; after that they're cached in `.build/`.

## Verifying Spore Cloud

The share URL changed when Spore Cloud moved onto Swifter — files are now served
under `/spores/` and the basket index lives at `/`:

```bash
curl -s http://<your-lan-ip>:8420/                  # browsable basket index
curl -sO http://<your-lan-ip>:8420/spores/<file>    # download one file
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