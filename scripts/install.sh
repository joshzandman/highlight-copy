#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="${HOME}/Applications"
APP="${APP_DIR}/HighlightCopy.app"
EXECUTABLE="HighlightCopy"
LABEL="com.joshzandman.HighlightCopy"
DOMAIN="gui/$(id -u)"

cd "$ROOT"
swift build -c release --product "$EXECUTABLE"
BIN_DIR="$(swift build -c release --product "$EXECUTABLE" --show-bin-path)"

mkdir -p "$APP_DIR"

# Unload a previous agent before replacing the binary it keeps alive.
launchctl bootout "${DOMAIN}/${LABEL}" >/dev/null 2>&1 || true
for _ in 1 2 3 4 5 6 7 8; do
  if ! pgrep -x "$EXECUTABLE" >/dev/null; then
    break
  fi
  killall "$EXECUTABLE" >/dev/null 2>&1 || true
  sleep 0.3
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "${BIN_DIR}/${EXECUTABLE}" "$APP/Contents/MacOS/${EXECUTABLE}"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
chmod +x "$APP/Contents/MacOS/${EXECUTABLE}"

# Ad-hoc signatures change every build, so a permission switch granted to the previous
# binary stops applying. Sign with the stable local certificate instead.
"$ROOT/scripts/ensure-signing-cert.sh"
KEYCHAIN="${HOME}/Library/Keychains/highlight-copy.keychain-db"
NAME="Highlight Copy Local"
security unlock-keychain -p highlight-copy "$KEYCHAIN"
HASH="$(security find-certificate -c "$NAME" -Z "$KEYCHAIN" | awk '/SHA-1 hash:/{print tolower($3); exit}')"
if [[ -z "$HASH" ]]; then
  echo "No signing certificate hash" >&2
  exit 1
fi
REQ="=designated => identifier \"${LABEL}\" and certificate leaf = H\"${HASH}\""
codesign --force --sign "$NAME" --keychain "$KEYCHAIN" -r "$REQ" "$APP"
REQ_OUT="$(codesign -d -r- "$APP" 2>&1 || true)"
echo "$REQ_OUT"
case "$REQ_OUT" in
  *"certificate leaf = H\"${HASH}\""*) ;;
  *) echo "Signature requirement is not stable" >&2; exit 1 ;;
esac

# -g launches the agent without stealing focus.
open -g "$APP"

for _ in 1 2 3 4 5 6 7 8 9 10; do
  if pgrep -x "$EXECUTABLE" >/dev/null; then
    echo "Launched ${APP}"
    exit 0
  fi
  sleep 0.3
done

echo "Highlight Copy did not start" >&2
exit 1
