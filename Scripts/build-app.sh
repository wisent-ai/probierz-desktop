#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
CONFIGURATION=${CONFIGURATION:-release}
PRODUCT=ProbierzDesktop
APP_NAME=Probierz
ICON_PRODUCT=probierz-desktop
# Where the operator launches the app from. A bundle left in .build is not
# launchable in practice: build directories get deleted, which strands the app.
INSTALLED_BUNDLE=${PROBIERZ_INSTALL_APP_PATH:-"$HOME/Applications/$APP_NAME.app"}
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

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
# The feed URL already exists in this repository, in
# .wisent-desktop-release.json - the release manifest wisent-desktop-update
# reads. Until 2026-08-31 this script stamped SUFeedURL only from
# WISENT_UPDATE_FEED_URL, so every build that did not export that variable,
# which includes every local and source build, shipped the empty SUFeedURL that
# App/Info.plist carries. Sparkle with no feed URL issues no request, so "Check
# for Updates…" did nothing at all.
#
# The manifest is now the default, the environment variable stays an override for
# a staging feed, and a bundle that would ship without a feed URL fails the build
# instead of being discovered months later by a user who never got an update.
RELEASE_MANIFEST="$ROOT/.wisent-desktop-release.json"
UPDATE_FEED_URL=${WISENT_UPDATE_FEED_URL:-}
if [ -z "$UPDATE_FEED_URL" ] && [ -f "$RELEASE_MANIFEST" ]; then
    command -v jq >/dev/null 2>&1 || {
        printf '%s\n' "jq is required to read $RELEASE_MANIFEST" >&2
        exit 1
    }
    UPDATE_FEED_URL=$(jq -r '.feed_url // empty' "$RELEASE_MANIFEST")
fi
case "$UPDATE_FEED_URL" in
    https://*) ;;
    '')
        printf '%s\n' "no update feed URL: set WISENT_UPDATE_FEED_URL, or .feed_url in $RELEASE_MANIFEST. An app with an empty SUFeedURL can never check for updates." >&2
        exit 1 ;;
    *)
        printf '%s\n' "update feed URL must use HTTPS: $UPDATE_FEED_URL" >&2
        exit 1 ;;
esac
/usr/libexec/PlistBuddy -c "Set :SUFeedURL $UPDATE_FEED_URL" "$CONTENTS/Info.plist"
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
IDENTITY_HELPER="$CONTENTS/Helpers/WisentIdentityKeychainHelper"
"$ROOT/.build/checkouts/wisent-desktop-auth/scripts/build-keychain-helper.sh" "$IDENTITY_HELPER"
if [ "${CODESIGN_IDENTITY#Developer ID Application:}" != "$CODESIGN_IDENTITY" ]; then
    codesign --force --deep --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$FRAMEWORKS/Sparkle.framework"
    codesign --force --options runtime --timestamp --identifier ai.wisent.identity.keychain-helper --sign "$CODESIGN_IDENTITY" "$IDENTITY_HELPER"
    codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$MACOS/$PRODUCT"
    codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$BUNDLE"
else
    codesign --force --deep --timestamp=none --sign "$CODESIGN_IDENTITY" "$FRAMEWORKS/Sparkle.framework"
    codesign --force --timestamp=none --identifier ai.wisent.identity.keychain-helper --sign "$CODESIGN_IDENTITY" "$IDENTITY_HELPER"
    codesign --force --timestamp=none --sign "$CODESIGN_IDENTITY" "$MACOS/$PRODUCT"
    codesign --force --timestamp=none --sign "$CODESIGN_IDENTITY" "$BUNDLE"
fi
codesign --verify --strict --deep "$BUNDLE"
printf 'Built %s\n' "$BUNDLE"

if [ "${PROBIERZ_INSTALL_AFTER_BUILD:-yes}" = no ]; then
    exit
fi

# Staged, then moved into place: a half-copied bundle at the launch path is worse
# than an old one, because it fails at exec instead of at build.
mkdir -p "$(dirname "$INSTALLED_BUNDLE")"
STAGING=$(mktemp -d "$(dirname "$INSTALLED_BUNDLE")/.$APP_NAME.installing.XXXXXXXX")
trap 'rm -rf "$STAGING"' EXIT INT TERM
ditto "$BUNDLE" "$STAGING/$APP_NAME.app"
codesign --verify --strict --deep "$STAGING/$APP_NAME.app"
rm -rf "$INSTALLED_BUNDLE"
mv "$STAGING/$APP_NAME.app" "$INSTALLED_BUNDLE"
rm -rf "$STAGING"
trap - EXIT INT TERM
# A bundle left in .build is not what the operator launches, and while it stays
# registered it competes for the ai.wisent.*.desktop sign-in URL scheme.
"$LSREGISTER" -u "$BUNDLE" >/dev/null 2>&1 || true
"$LSREGISTER" -f "$INSTALLED_BUNDLE"
printf 'Installed %s\n' "$INSTALLED_BUNDLE"

RESTART_APP=${WISENT_RESTART_APP:-"$SCRIPT_DIR/wisent-restart-app"}
if [ "${WISENT_RESTART_AFTER_BUILD:-1}" != 0 ] && [ -x "$RESTART_APP" ]; then
    "$RESTART_APP" --if-running "$INSTALLED_BUNDLE"
fi

