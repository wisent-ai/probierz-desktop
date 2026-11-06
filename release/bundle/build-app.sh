#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
# The Swift configuration is release unless CONFIGURATION names another.
if [ -n "${CONFIGURATION+set}" ]; then
    SWIFT_CONFIGURATION=$CONFIGURATION
else
    SWIFT_CONFIGURATION=release
fi
PRODUCT=ProbierzDesktop
APP_NAME=Probierz
ICON_PRODUCT=probierz-desktop
# Where the operator launches the app from: ~/Applications unless
# PROBIERZ_INSTALL_APP_PATH names another place. A bundle left in .build is not
# launchable in practice: build directories get deleted, which strands the app.
if [ -n "${PROBIERZ_INSTALL_APP_PATH+set}" ]; then
    INSTALLED_BUNDLE=$PROBIERZ_INSTALL_APP_PATH
else
    INSTALLED_BUNDLE="$HOME/Applications/$APP_NAME.app"
fi
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
# Installed files: data readable by everyone and writable by its owner;
# executables additionally executable by everyone.
DATA_MODE=u=rw,go=r
EXECUTABLE_MODE=u=rwx,go=rx

swift build --package-path "$ROOT" --configuration "$SWIFT_CONFIGURATION" --product "$PRODUCT"
BIN_DIR=$(swift build --package-path "$ROOT" --configuration "$SWIFT_CONFIGURATION" --show-bin-path)
BUNDLE="$ROOT/.build/$APP_NAME.app"
CONTENTS="$BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
FRAMEWORKS="$CONTENTS/Frameworks"

rm -rf "$BUNDLE"
mkdir -p "$MACOS" "$RESOURCES" "$FRAMEWORKS"
install -m "$DATA_MODE" "$ROOT/App/Info.plist" "$CONTENTS/Info.plist"
# A release build states its version; the build number is the version unless
# the release states one of its own.
if [ -n "${WISENT_RELEASE_VERSION+set}" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $WISENT_RELEASE_VERSION" "$CONTENTS/Info.plist"
    if [ -n "${WISENT_BUILD_NUMBER+set}" ]; then
        /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $WISENT_BUILD_NUMBER" "$CONTENTS/Info.plist"
    else
        /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $WISENT_RELEASE_VERSION" "$CONTENTS/Info.plist"
    fi
fi
# Stado resolves the deployment's update origin; source carries no host.
# WISENT_UPDATE_FEED_URL explicitly overrides it for a staging feed.
if [ -n "${WISENT_UPDATE_FEED_URL+set}" ]; then
    UPDATE_FEED_URL=$WISENT_UPDATE_FEED_URL
else
    UPDATE_FEED_URL=$(stado web origin url /api/release/appcast --query "product=$ICON_PRODUCT")
fi
case "$UPDATE_FEED_URL" in
    https://*) ;;
    '')
        printf '%s\n' "Stado returned no update feed URL; declare an appcast origin or set WISENT_UPDATE_FEED_URL." >&2
        false ;;
    *)
        printf '%s\n' "update feed URL must use HTTPS: $UPDATE_FEED_URL" >&2
        false ;;
esac
/usr/libexec/PlistBuddy -c "Set :SUFeedURL $UPDATE_FEED_URL" "$CONTENTS/Info.plist"
install -m "$EXECUTABLE_MODE" "$BIN_DIR/$PRODUCT" "$MACOS/$PRODUCT"
SPARKLE_FRAMEWORK="$BIN_DIR/Sparkle.framework"
if [ ! -d "$SPARKLE_FRAMEWORK" ]; then
    printf '%s\n' "Sparkle.framework is unavailable: $SPARKLE_FRAMEWORK" >&2
    false
fi
ditto "$SPARKLE_FRAMEWORK" "$FRAMEWORKS/Sparkle.framework"
if ! otool -l "$MACOS/$PRODUCT" | grep -q '@executable_path/../Frameworks'; then
    install_name_tool -add_rpath '@executable_path/../Frameworks' "$MACOS/$PRODUCT"
fi
if [ -f "$ROOT/App/AppIcon.icns" ]; then
    install -m "$DATA_MODE" "$ROOT/App/AppIcon.icns" "$RESOURCES/AppIcon.icns"
else
    sh "$SCRIPT_DIR/import-brand-icon.sh" "$ICON_PRODUCT" "$RESOURCES/AppIcon.icns"
fi
for resource_bundle in "$BIN_DIR"/*.bundle; do
    [ -d "$resource_bundle" ] || continue
    ditto "$resource_bundle" "$RESOURCES/$(basename "$resource_bundle")"
done

IDENTITY_HELPER="$CONTENTS/Helpers/WisentIdentityKeychainHelper"
IDENTITY_BUILD_DIR="$ROOT/.build/identity-helper"
swift build --package-path "$ROOT/.build/checkouts/wisent-desktop-auth" \
    --configuration release --product wisent-identity-keychain-helper --scratch-path "$IDENTITY_BUILD_DIR"
mkdir -p "$(dirname "$IDENTITY_HELPER")"
install -m "$EXECUTABLE_MODE" "$IDENTITY_BUILD_DIR/release/wisent-identity-keychain-helper" "$IDENTITY_HELPER"

# The shared signer signs SIGN_TARGET as SIGN_IDENTIFIER and verifies continuity
# with SIGN_PREVIOUS. A release names its certificate in WISENT_CODESIGN_IDENTITY
# (a Developer ID one is signed with the hardened runtime Apple notarizes);
# otherwise Stado selects the declared Skarbiec certificate itself, so no
# identity is guessed from whatever the login keychain holds.
sign_target() {
    if [ -n "${WISENT_CODESIGN_IDENTITY+set}" ]; then
        case "$WISENT_CODESIGN_IDENTITY" in
            'Developer ID Application:'*)
                stado product signing sign "$SIGN_TARGET" --identifier "$SIGN_IDENTIFIER" \
                    --previous "$SIGN_PREVIOUS" --identity "$WISENT_CODESIGN_IDENTITY" --hardened-runtime --json ;;
            *)
                stado product signing sign "$SIGN_TARGET" --identifier "$SIGN_IDENTIFIER" \
                    --previous "$SIGN_PREVIOUS" --identity "$WISENT_CODESIGN_IDENTITY" --json ;;
        esac
    else
        stado product signing sign "$SIGN_TARGET" --identifier "$SIGN_IDENTIFIER" \
            --previous "$SIGN_PREVIOUS" --json
    fi
}
SIGN_TARGET=$IDENTITY_HELPER
SIGN_IDENTIFIER=ai.wisent.identity.keychain-helper
SIGN_PREVIOUS="$INSTALLED_BUNDLE/Contents/Helpers/WisentIdentityKeychainHelper"
sign_target
SIGN_TARGET=$BUNDLE
SIGN_IDENTIFIER=com.wisent.probierz.desktop
SIGN_PREVIOUS=$INSTALLED_BUNDLE
sign_target
codesign --verify --strict --deep "$BUNDLE"
printf 'Built %s\n' "$BUNDLE"

# The build installs unless PROBIERZ_INSTALL_AFTER_BUILD says no.
if [ -n "${PROBIERZ_INSTALL_AFTER_BUILD+set}" ] && [ "$PROBIERZ_INSTALL_AFTER_BUILD" = no ]; then
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
# registered it competes for the com.wisent.*.desktop sign-in URL scheme, so it
# is unregistered. `lsregister -u` also exits non-zero over the Spotlight
# importer's own failure to scan the .build copy, after the installed copy is
# already in place; that failure is said, with lsregister's own output left
# visible above, and the installed copy is still registered and restarted.
if ! "$LSREGISTER" -u "$BUNDLE"; then
    printf '%s\n' "lsregister did not unregister $BUNDLE (its output above says why); registering the installed copy anyway." >&2
fi
"$LSREGISTER" -f "$INSTALLED_BUNDLE"
printf 'Installed %s\n' "$INSTALLED_BUNDLE"
# The build restarts nothing: `stado product install probierz --surface desktop`
# restarts the app it places when it runs, and `stado product restart
# --if-running <bundle>` restarts a bundle placed any other way.
