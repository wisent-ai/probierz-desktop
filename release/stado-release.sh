#!/bin/bash
set -euo pipefail

UPDATER_SHA256="1f3c919e7e15ef6736a7c9c841ca185cb487e502c0da39be68aa1aa8b487af47"
SWIFTPM_SHA256="1afb0215091d97ef0a1c05ce93035d91e83af8b09eaaa48d369ba1f3c7c769f4"
PRODUCT="Probierz"
PRODUCT_SLUG="probierz-desktop"

load_contract() {
  : "${WISENT_VERSION:?WISENT_VERSION is required}"
  : "${WISENT_SOURCE_DIR:?WISENT_SOURCE_DIR is required}"
  : "${WISENT_OUTPUT_DIR:?WISENT_OUTPUT_DIR is required}"
  : "${WISENT_PLATFORM:?WISENT_PLATFORM is required}"
  : "${WISENT_INPUTS_DIR:?WISENT_INPUTS_DIR is required}"
  [ "$WISENT_PLATFORM" = "darwin-arm64" ] || { printf 'unsupported platform: %s\n' "$WISENT_PLATFORM" >&2; exit 1; }
}

verify_input() {
  [ -f "$1" ] || { printf 'missing immutable input: %s\n' "$1" >&2; exit 1; }
  [ "$(shasum -a 256 "$1" | awk '{print $1}')" = "$2" ] || { printf 'immutable input digest mismatch: %s\n' "$1" >&2; exit 1; }
}

prepare_source() {
  updater="$WISENT_INPUTS_DIR/wisent-desktop-update.tar.gz"
  swiftpm="$WISENT_INPUTS_DIR/swiftpm-cache.tar.gz"
  verify_input "$updater" "$UPDATER_SHA256"
  verify_input "$swiftpm" "$SWIFTPM_SHA256"
  work="$WISENT_OUTPUT_DIR/work"
  source="$work/source"
  rm -rf "$work"
  # Throwaway state is removed by the code that made it: the source copy and
  # everything signed inside it end with the run.
  trap 'rm -rf "$work"' EXIT
  mkdir -p "$source"
  rsync -a --exclude .git --exclude .build "$WISENT_SOURCE_DIR/" "$source/"
  tar -xzf "$swiftpm" -C "$source"
}

compile_source() {
  load_contract
  prepare_source
  swift build --package-path "$source" --configuration release --product ProbierzDesktop --disable-automatic-resolution
}

build_release() {
  load_contract
  : "${MACOS_CERT_P12:?MACOS_CERT_P12 is required}"
  : "${MACOS_CERT_PASSWORD:?MACOS_CERT_PASSWORD is required}"
  : "${MACOS_SIGN_IDENTITY:?MACOS_SIGN_IDENTITY is required}"
  : "${AC_API_KEY_ID:?AC_API_KEY_ID is required}"
  : "${AC_API_ISSUER_ID:?AC_API_ISSUER_ID is required}"
  : "${AC_API_KEY_P8:?AC_API_KEY_P8 is required}"
  : "${SPARKLE_PRIVATE_KEY:?SPARKLE_PRIVATE_KEY is required}"
  : "${SPARKLE_PUBLIC_KEY:?SPARKLE_PUBLIC_KEY is required}"
  case "$MACOS_SIGN_IDENTITY" in 'Developer ID Application:'*) ;; *) printf 'Developer ID Application identity required\n' >&2; exit 1 ;; esac
  prepare_source
  release="$WISENT_OUTPUT_DIR/release"
  evidence="$WISENT_OUTPUT_DIR/evidence"
  mkdir -p "$release" "$evidence"
  keychain="$work/release.keychain-db"
  cert="$work/developer-id.p12"
  sparkle_key="$work/sparkle-private-key"
  keychain_password="$(uuidgen)"
  cleanup() {
    security delete-keychain "$keychain" >/dev/null 2>&1 || true
    rm -f "$cert" "$sparkle_key"
    rm -rf "$work"
  }
  trap cleanup EXIT
  printf '%s' "$MACOS_CERT_P12" | base64 -D > "$cert"
  printf '%s' "$SPARKLE_PRIVATE_KEY" > "$sparkle_key"
  chmod 600 "$sparkle_key"
  security create-keychain -p "$keychain_password" "$keychain"
  security set-keychain-settings -lut 21600 "$keychain"
  security unlock-keychain -p "$keychain_password" "$keychain"
  security import "$cert" -k "$keychain" -P "$MACOS_CERT_PASSWORD" -T /usr/bin/codesign
  security list-keychains -d user -s "$keychain"
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain" >/dev/null

  # From the fleet's declared public origin; a separate assignment so a
  # refusal stops the build instead of stamping an empty feed.
  feed_url="$(stado web origin url /api/release/appcast --query "product=$PRODUCT_SLUG")"
  WISENT_RELEASE_VERSION="$WISENT_VERSION" \
  WISENT_BUILD_NUMBER="$WISENT_VERSION" \
  WISENT_UPDATE_FEED_URL="$feed_url" \
  WISENT_CODESIGN_IDENTITY="$MACOS_SIGN_IDENTITY" \
  WISENT_RESTART_AFTER_BUILD=0 \
    "$source/release/bundle/build-app.sh"

  app="$source/.build/$PRODUCT.app"
  [ -d "$app" ] || { printf 'release bundle was not produced: %s\n' "$app" >&2; exit 1; }
  # Installed copies trust only the SUPublicEDKey they carry, so an app whose
  # key is not the public half of the key this release signs with could never update.
  [ "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$app/Contents/Info.plist")" = "$SPARKLE_PUBLIC_KEY" ] || { printf 'SUPublicEDKey is not the public half of the Sparkle key this release signs with\n' >&2; exit 1; }
  stado product signing notarize --app "$app" --evidence "$evidence/notary.json"

  staged_app="$release/$PRODUCT.app"
  archive="$release/$PRODUCT.zip"
  ditto "$app" "$staged_app"
  find "$staged_app" -exec touch -h -t 200001010000 {} +
  COPYFILE_DISABLE=1 ditto -c -k --sequesterRsrc --keepParent "$staged_app" "$archive"
  signer="$(find "$source/.build" -type f -path '*/Sparkle/bin/sign_update' -print -quit)"
  [ -x "$signer" ] || { printf 'Sparkle sign_update was not resolved\n' >&2; exit 1; }
  signature_line="$("$signer" --ed-key-file "$sparkle_key" "$archive")"
  case "$signature_line" in *'sparkle:edSignature='*) ;; *) printf 'Sparkle signature was not produced\n' >&2; exit 1 ;; esac
  printf '%s\n' "$signature_line" > "$archive.sparkle-signature"
  # The enclosure is the update archive inside this very release, from the
  # fleet's declared public origin; the XML attribute needs its query
  # separators escaped.
  archive_url="$(stado web origin url /api/release/sparkle --query "product=$PRODUCT_SLUG" --query "version=$WISENT_VERSION" --query "file=$PRODUCT.zip" | sed 's/&/\&amp;/g')"
  printf '%s\n' '<?xml version="1.0" encoding="utf-8"?>' "<rss version=\"2.0\" xmlns:sparkle=\"http://www.andymatuschak.org/xml-namespaces/sparkle\"><channel><title>$PRODUCT updates</title><item><title>$PRODUCT $WISENT_VERSION</title><sparkle:version>$WISENT_VERSION</sparkle:version><sparkle:shortVersionString>$WISENT_VERSION</sparkle:shortVersionString><sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion><enclosure url=\"$archive_url\" $signature_line type=\"application/octet-stream\"/></item></channel></rss>" > "$release/appcast.xml"
  archive_sha="$(shasum -a 256 "$archive" | awk '{print $1}')"
  appcast_sha="$(shasum -a 256 "$release/appcast.xml" | awk '{print $1}')"
  signature_sha="$(shasum -a 256 "$archive.sparkle-signature" | awk '{print $1}')"
  printf '{"schema_version":1,"product":"%s","version":"%s","platform":"%s","archive_sha256":"%s","appcast_sha256":"%s","signature_sha256":"%s","updater_source_sha256":"%s","swiftpm_cache_sha256":"%s","notarized":true}\n' "$PRODUCT_SLUG" "$WISENT_VERSION" "$WISENT_PLATFORM" "$archive_sha" "$appcast_sha" "$signature_sha" "$UPDATER_SHA256" "$SWIFTPM_SHA256" > "$evidence/release.json"
  shasum -a 256 "$archive" "$archive.sparkle-signature" "$release/appcast.xml" > "$evidence/DIGESTS"
}

case "${1:-}" in
  compile) compile_source ;;
  build) build_release ;;
  *) printf 'usage: %s {compile|build}\n' "$0" >&2; exit 64 ;;
esac
