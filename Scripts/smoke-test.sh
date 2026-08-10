#!/bin/bash
#
# Smoke-test a running Fungi's Spore Cloud over loopback.
#
# Covers the path-traversal fix, which CI cannot reach: compiling proves the
# guard exists, not that it holds. Start Fungi first, then run this.
#
#   ./Scripts/bundle.sh release && open .build/Fungi.app
#   ./Scripts/smoke-test.sh
#
set -uo pipefail

PORT="${FUNGI_PORT:-8420}"
BASE="http://127.0.0.1:$PORT"
pass=0
fail=0

ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail + 1)); }
info() { printf '\033[1m%s\033[0m\n' "$1"; }

code() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$1" 2>/dev/null; }
body() { curl -s --max-time 5 "$1" 2>/dev/null; }

info "Spore Cloud on $BASE"
if [ "$(code "$BASE/")" != "200" ]; then
  echo "  Nothing answering on port $PORT."
  echo "  Launch Fungi, then check Settings > Enable Spore Cloud."
  exit 1
fi

# Locate the Basket the app is actually serving.
BASKET="$HOME/Library/Mobile Documents/com~apple~CloudDocs/Fungi/Basket"
[ -d "$BASKET" ] || BASKET="$(find "$HOME/Library/Mobile Documents" -type d -name Basket -path '*Fungi*' 2>/dev/null | head -1)"
if [ ! -d "$BASKET" ]; then
  echo "  Could not find the Basket directory; is iCloud Drive on?"
  exit 1
fi
echo "  Basket: $BASKET"
echo

info "Serving"
[ "$(code "$BASE/")" = "200" ] && ok "index responds 200" || bad "index responds 200"
body "$BASE/" | grep -q "Spore Cloud" && ok "index is the Fungi page" || bad "index is the Fungi page"

CANARY="fungi-smoke-$$.txt"
MARKER="spore-cloud-canary-$$"
printf '%s\n' "$MARKER" > "$BASKET/$CANARY"
trap 'rm -f "$BASKET/$CANARY"' EXIT
sleep 1

[ "$(code "$BASE/spores/$CANARY")" = "200" ] && ok "serves a real Basket file" || bad "serves a real Basket file"
body "$BASE/spores/$CANARY" | grep -q "$MARKER" && ok "file contents intact" || bad "file contents intact"
echo

info "Path traversal must be refused"
# HttpRouter percent-decodes the token before routing, so these decode to real
# traversals inside the handler. Any 200 here is a LAN-readable file leak.
for probe in \
  '..%2F..%2F..%2Fetc%2Fpasswd' \
  '..%2F..%2F..%2F..%2F..%2Fetc%2Fpasswd' \
  '%2Fetc%2Fpasswd' \
  '..%2F..%2F..%2Fetc%2Fhosts' \
  '....%2F%2F....%2F%2Fetc%2Fpasswd' \
  '..%252F..%252Fetc%252Fpasswd' \
  '.ssh' \
  '.DS_Store'
do
  status=$(code "$BASE/spores/$probe")
  content=$(body "$BASE/spores/$probe")
  if [ "$status" = "200" ]; then
    bad "LEAK: /spores/$probe returned 200"
  elif printf '%s' "$content" | grep -qE '^root:|localhost'; then
    bad "LEAK: /spores/$probe returned system file contents"
  else
    ok "refused /spores/$probe ($status)"
  fi
done
echo

info "Escaping the Basket by absolute path must fail"
status=$(code "$BASE/spores/etc/passwd")
[ "$status" != "200" ] && ok "refused /spores/etc/passwd ($status)" || bad "LEAK: /spores/etc/passwd returned 200"
echo

printf '\033[1m%d passed, %d failed\033[0m\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
