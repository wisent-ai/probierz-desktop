#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
CONFIGURATION=${CONFIGURATION:-release}
PRODUCT=ProbierzDesktop
APP_NAME=Probierz
ICON_PRODUCT=probierz-desktop

swift build --package-path "$ROOT" --configuration "$CONFIGURATION" --product "$PRODUCT"
BIN_DIR=$(swift build --package-path "$ROOT" --configuration "$CONFIGURATION" --show-bin-path)
BUNDLE="$ROOT/.build/$APP_NAME.app"
CONTENTS="$BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
FRAMEWORKS="$CONTENTS/Frameworks"

rm -rf "$BUNDLE"
mkdir -p "$MACOS" "$RESOURCES" "$FRAMEWORKS"
install -m 0644 "$ROOT/App/Info.plist" "$CONTENTS/Info.plist"
if [ -n "${WISENT_RELEASE_VERSION:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $WISENT_RELEASE_VERSION" "$CONTENTS/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${WISENT_BUILD_NUMBER:-$WISENT_RELEASE_VERSION}" "$CONTENTS/Info.plist"
fi
if [ -n "${WISENT_UPDATE_FEED_URL:-}" ]; then
    case "$WISENT_UPDATE_FEED_URL" in https://*) ;; *) printf '%s\n' "WISENT_UPDATE_FEED_URL must use HTTPS" >&2; exit 1 ;; esac
    /usr/libexec/PlistBuddy -c "Set :SUFeedURL $WISENT_UPDATE_FEED_URL" "$CONTENTS/Info.plist"
fi
install -m 0755 "$BIN_DIR/$PRODUCT" "$MACOS/$PRODUCT"
SPARKLE_FRAMEWORK="$BIN_DIR/Sparkle.framework"
test -d "$SPARKLE_FRAMEWORK" || { printf '%s\n' "Sparkle.framework is unavailable: $SPARKLE_FRAMEWORK" >&2; exit 1; }
ditto "$SPARKLE_FRAMEWORK" "$FRAMEWORKS/Sparkle.framework"
if ! otool -l "$MACOS/$PRODUCT" | grep -q '@executable_path/../Frameworks'; then
    install_name_tool -add_rpath '@executable_path/../Frameworks' "$MACOS/$PRODUCT"
fi
if [ -f "$ROOT/App/AppIcon.icns" ]; then
    install -m 0644 "$ROOT/App/AppIcon.icns" "$RESOURCES/AppIcon.icns"
else
    sh "$SCRIPT_DIR/import-brand-icon.sh" "$ICON_PRODUCT" "$RESOURCES/AppIcon.icns"
fi
for resource_bundle in "$BIN_DIR"/*.bundle; do
    [ -d "$resource_bundle" ] || continue
    ditto "$resource_bundle" "$RESOURCES/$(basename "$resource_bundle")"
done

CODESIGN_IDENTITY=${WISENT_CODESIGN_IDENTITY:-}
if [ -z "$CODESIGN_IDENTITY" ]; then
    CODESIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk -F '"' '/Developer ID Application:/ { print $2; exit }')
fi
if [ -z "$CODESIGN_IDENTITY" ]; then
    CODESIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk -F '"' '/Apple Development:/ { print $2; exit }')
fi
if [ -z "$CODESIGN_IDENTITY" ] || [ "$CODESIGN_IDENTITY" = "-" ]; then
    printf '%s\n' "Stable Developer ID Application or Apple Development signing identity is required; refusing ad-hoc signing." >&2
    exit 1
fi
if [ "${CODESIGN_IDENTITY#Developer ID Application:}" != "$CODESIGN_IDENTITY" ]; then
    codesign --force --deep --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$FRAMEWORKS/Sparkle.framework"
    codesign --force --options runtime --timestamp --entitlements "$ROOT/App/WisentDesktop.entitlements" --sign "$CODESIGN_IDENTITY" "$MACOS/$PRODUCT"
    codesign --force --options runtime --timestamp --entitlements "$ROOT/App/WisentDesktop.entitlements" --sign "$CODESIGN_IDENTITY" "$BUNDLE"
else
    codesign --force --deep --timestamp=none --sign "$CODESIGN_IDENTITY" "$FRAMEWORKS/Sparkle.framework"
    codesign --force --timestamp=none --entitlements "$ROOT/App/WisentDesktop.entitlements" --sign "$CODESIGN_IDENTITY" "$MACOS/$PRODUCT"
    codesign --force --timestamp=none --entitlements "$ROOT/App/WisentDesktop.entitlements" --sign "$CODESIGN_IDENTITY" "$BUNDLE"
fi
codesign --verify --strict --deep "$BUNDLE"
printf 'Built %s\n' "$BUNDLE"

RESTART_APP=${WISENT_RESTART_APP:-"$SCRIPT_DIR/wisent-restart-app"}
if [ "${WISENT_RESTART_AFTER_BUILD:-1}" != 0 ] && [ -x "$RESTART_APP" ]; then
    "$RESTART_APP" --if-running "$BUNDLE"
fi

