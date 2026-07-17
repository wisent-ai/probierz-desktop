#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
PRODUCT="ProbierzDesktop"
APP_NAME="Probierz"

swift build --package-path "$ROOT" --configuration release --product "$PRODUCT"
BIN_DIR=$(swift build --package-path "$ROOT" --configuration release --show-bin-path)
BUNDLE="$ROOT/.build/$APP_NAME.app"
CONTENTS="$BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

rm -rf "$BUNDLE"
mkdir -p "$MACOS" "$RESOURCES"
install -m 0644 "$ROOT/App/Info.plist" "$CONTENTS/Info.plist"
install -m 0755 "$BIN_DIR/$PRODUCT" "$MACOS/$PRODUCT"
sh "$SCRIPT_DIR/import-brand-icon.sh" probierz-desktop "$RESOURCES/AppIcon.icns"

if command -v codesign >/dev/null 2>&1; then
    codesign --force --deep --sign - "$BUNDLE"
fi

printf 'Built %s\n' "$BUNDLE"

RESTART_APP=${WISENT_RESTART_APP:-"$SCRIPT_DIR/wisent-restart-app"}
if [ "${WISENT_RESTART_AFTER_BUILD:-1}" != 0 ] && [ -x "$RESTART_APP" ]; then
    "$RESTART_APP" --if-running "$BUNDLE"
fi
