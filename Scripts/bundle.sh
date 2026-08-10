#!/bin/bash
#
# Assemble Fungi.app from the SwiftPM executable.
#
# `swift run` produces a bare Mach-O binary with no Info.plist, which macOS
# treats as having no usage descriptions at all — so the first call into the
# mic, Speech, EventKit or Apple Events kills the process. Fungi has to ship
# as a real bundle for Echo, Almanac and Post to work.
#
#   ./Scripts/bundle.sh              # debug
#   ./Scripts/bundle.sh release      # release
#
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/.build/Fungi.app"

echo "==> Building ($CONFIG)"
swift build -c "$CONFIG" --package-path "$ROOT"

BIN="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)/Fungi"
[ -x "$BIN" ] || { echo "error: no executable at $BIN" >&2; exit 1; }

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Fungi"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# Fail loudly on a malformed plist rather than shipping a bundle macOS ignores.
plutil -lint "$APP/Contents/Info.plist"

# TCC keys an app by its code signature. Without one, every permission grant is
# forgotten as soon as the binary is rebuilt. An ad-hoc signature is enough to
# keep grants stable across local builds; a real Developer ID is needed only to
# distribute to other machines.
echo "==> Ad-hoc signing"
codesign --force --deep --sign - "$APP"
codesign --verify --verbose "$APP" 2>&1 | sed 's/^/    /'

cat <<EOF

Built $APP

  open $APP            # launch it (look for 🍄 in the menu bar)

First launch prompts for permissions as you use each feature. Trellis
(Accessibility) and Cricket (Input Monitoring) must be granted by hand in
System Settings > Privacy & Security — macOS gives those no in-app prompt.
EOF
