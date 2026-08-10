# Shelf

An open-source macOS menu bar app inspired by [Droppy](https://getdroppy.app/). A productivity shelf in your menu bar with clipboard history, file tray, timers, and media controls.

## Features

- **Clipboard manager** — history of text, images, and files you copied. Search, click to copy back.
- **File tray** — drag files into the popover to keep them nearby.
- **Timers** — quick countdown timers with notifications.
- **Media controls** — play/pause/skip from the menu bar.
- **Launch at login** — toggleable from Settings tab.
- **100% on-device** — clipboard and timer data stays in `~/Library/Application Support/Shelf/`.

## Build

Requires Xcode 15+ and macOS 13+.

```bash
swift build -c release
cp .build/release/Shelf /usr/local/bin/shelf
shelf
```

Or run directly during development:

```bash
swift run
```

## Permissions

- **Accessibility** — required for media control shortcuts and global hotkeys (if added later).
- **Notifications** — required for timer alerts.

## Architecture

- `ClipboardManager` — polls `NSPasteboard.general` every 0.7s, persists to JSON.
- `TimerManager` — `Timer.scheduledTimer` ticker, notifications via `UNUserNotificationCenter`.
- `MediaController` — AppleScript `System Events` keystrokes for media keys (avoids private MediaRemote framework).
- `PopoverViewController` — tab-based UI: Clipboard / Files / Timers / Media / Settings.
- `AppDelegate` — NSStatusItem with `NSPopover`, accessory activation policy (no dock icon).

## Why not just use Droppy?

Droppy is a paid one-time app (~ $30). Shelf is free, open-source (MIT), and small enough to hack on. It does less — no Dynamic Island pill, no lock screen widgets, no Droppy Cloud — but covers the core workflow.

## License

MIT. See `LICENSE`.
