# Shelf

An open-source macOS menu bar app inspired by [Droppy](https://getdroppy.app/). A productivity shelf in your menu bar with clipboard history, drag-drop file tray, timers, media controls, and a floating Dynamic Island-style pill.

## Features

- **Clipboard manager** — history of text, images, and files you copied. Search, click to copy back. Persists across sessions.
- **Drag-drop file tray** — drop any file into the Files tab. It gets copied to your iCloud Drive and you can reveal it in Finder. Files sync across all your Macs.
- **Floating pill (Dynamic Island style)** — a small always-on-top panel showing the time, clipboard count, and play/pause. Toggle from Settings.
- **Timers** — quick countdown timers with notifications.
- **Media controls** — play/pause/skip from the menu bar.
- **Launch at login** — toggleable from Settings.
- **iCloud sync** — clipboard history, timers, and dropped files all live in `~/Library/Mobile Documents/com~apple~CloudDocs/Shelf/`. Syncs to your other Macs.

## Storage layout

```
~/Library/Mobile Documents/com~apple~CloudDocs/Shelf/
├── clips.json        # clipboard history
├── timers.json       # active timers
├── clipImages/       # captured image clipboard items
└── Drops/            # files dropped into the tray
```

If iCloud Drive isn't available, falls back to `~/Library/Application Support/Shelf/`.

## Build

Requires Xcode 15+ and macOS 13+.

```bash
swift run
```

Or build a release binary:

```bash
swift build -c release
cp .build/release/Shelf /usr/local/bin/shelf
shelf
```

## Permissions

- **Accessibility** — for media control shortcuts (AppleScript)
- **Notifications** — for timer alerts

## Architecture

- `Storage` — iCloud-first, local fallback. Detects `~/Library/Mobile Documents/com~apple~CloudDocs/` and uses it as the primary write target so iCloud syncs everything.
- `ClipboardManager` — polls `NSPasteboard.general` every 0.7s, persists as JSON in iCloud.
- `TimerManager` — `Timer.scheduledTimer` ticker, notifications via `UNUserNotificationCenter`.
- `MediaController` — AppleScript `System Events` keystrokes for media keys (avoids private MediaRemote framework).
- `DropView` — drag destination with visual feedback on enter/exit, copies files to iCloud.
- `PillController` — `NSPanel` with `.statusBar` window level, floats over fullscreen apps via `fullScreenAuxiliary` collectionBehavior.
- `PopoverViewController` — tab-based UI: Clipboard / Files / Timers / Media / Settings.
- `AppDelegate` — NSStatusItem with `NSPopover`, accessory activation policy (no dock icon).

## What it does vs Droppy

| Feature | Shelf | Droppy |
|---|---|---|
| Menu bar popover | ✓ | ✓ |
| Clipboard history | ✓ | ✓ |
| Drag-drop file tray | ✓ | ✓ |
| Timers | ✓ | ✓ |
| Media controls | ✓ | ✓ |
| Dynamic Island pill | ✓ | ✓ |
| Lock screen widgets | ✗ | ✓ |
| Droppy Cloud (share links) | ✗ | ✓ |
| Per-Droplet extensions | ✗ | ✓ |
| iCloud sync | ✓ | partial |
| Open source | ✓ (MIT) | ✗ (paid) |

## License

MIT. See `LICENSE`.
