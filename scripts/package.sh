#!/usr/bin/env zsh
# Build a Release Jarvis.app and package it as a disk image in dist/.
#
# Usage: scripts/package.sh [--install | --release]
#   --install   also copy Jarvis.app to /Applications (or ~/Applications) and launch it
#   --release   public build: Developer ID signature, notarization and stapling are required;
#               prints the SHA-256 for the GitHub release and the Homebrew cask
#
# Signing identity: see pick_identity in scripts/common.sh. macOS binds Microphone and
# Accessibility grants to the identity, so keep using the same one on a Mac.
# Notarization uses the notarytool keychain profile $JARVIS_NOTARY_PROFILE (default
# "jarvis-notary"), created once with `xcrun notarytool store-credentials`.
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-}"
[[ -z "$MODE" || "$MODE" == --install || "$MODE" == --release ]] || {
  echo "usage: scripts/package.sh [--install | --release]"
  exit 2
}

source scripts/common.sh
prepare_project

VERSION=$(grep -E '^\s*MARKETING_VERSION:' project.yml | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
BUILD=$(grep -E '^\s*CURRENT_PROJECT_VERSION:' project.yml | head -1 | sed -E 's/[^0-9]//g')
NOTARY_PROFILE="${JARVIS_NOTARY_PROFILE:-jarvis-notary}"
pick_identity

if [[ "$MODE" == --release ]]; then
  [[ "$IDENTITY_NAME" == "Developer ID Application:"* ]] || {
    echo "✗ --release needs a Developer ID Application certificate (found: $IDENTITY_NAME)."
    exit 1
  }
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 || {
    echo "✗ notarytool profile \"$NOTARY_PROFILE\" missing. Create it once with:"
    echo "  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <Apple ID> --team-id <team id>"
    exit 1
  }
  [[ -z "$(git status --porcelain)" ]] || { echo "✗ working tree has uncommitted changes"; exit 1; }
fi

DERIVED="$PWD/DerivedData"
DIST="$PWD/dist"
APP="$DERIVED/Build/Products/Release/Jarvis.app"
DMG="$DIST/JarvisSimple-$VERSION-arm64.dmg"

echo "▶ Building Jarvis Simple $VERSION ($BUILD), signing: $IDENTITY_NAME"
rm -rf "$APP"
xcode_build Release
[[ -d "$APP" ]] || { echo "build produced no app"; exit 1; }

# Sign inside-out: nested code first, then the app with its entitlements. A secure timestamp is
# required for notarization and harmless otherwise (skipped for ad-hoc).
SIGN_FLAGS=(--force --options runtime --sign "$IDENTITY")
[[ "$IDENTITY" == "-" ]] || SIGN_FLAGS+=(--timestamp)
find "$APP/Contents" -depth \( -name "*.dylib" -o -name "*.framework" -o -name "*.xpc" -o -name "*.appex" \) \
  -print0 | while IFS= read -r -d '' nested; do
  codesign "${SIGN_FLAGS[@]}" "$nested"
done
codesign "${SIGN_FLAGS[@]}" --entitlements App/Jarvis.entitlements "$APP"
codesign --verify --deep --strict "$APP"
echo "▶ codesign OK"

mkdir -p "$DIST"
rm -f "$DMG"
# Disk image: drag-to-Applications layout.
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Jarvis Simple $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
[[ "$IDENTITY" == "-" ]] || codesign --force --timestamp --sign "$IDENTITY" "$DMG"
echo "▶ $DMG"

if [[ "$MODE" == --release ]]; then
  echo "▶ Notarizing (usually a few minutes)…"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  # Check the app as Gatekeeper sees it after a download.
  MOUNT=$(mktemp -d)
  hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MOUNT" "$DMG"
  spctl --assess --type execute --verbose=2 "$MOUNT/Jarvis.app"
  hdiutil detach -quiet "$MOUNT"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
  echo "▶ notarized and stapled"
fi

# File name only: the checksum file is published next to the disk image.
(cd "$DIST" && shasum -a 256 "${DMG:t}" | tee "${DMG:t}.sha256")

if [[ "$MODE" == --install ]]; then
  # Prefer /Applications (admin rights via sudo when needed); otherwise fall back to
  # ~/Applications, which Spotlight and Launchpad index as well.
  TARGET=/Applications
  SUDO=""
  if [[ ! -w /Applications ]]; then
    if [[ -t 0 ]] && sudo -v -p "Admin password for /Applications (Enter to skip → ~/Applications): " 2>/dev/null; then
      SUDO=sudo
    else
      TARGET="$HOME/Applications"
      mkdir -p "$TARGET"
      echo "ℹ️  /Applications is not writable; installing to ~/Applications instead."
      echo "   For /Applications, re-run from an admin account."
    fi
  fi
  pkill -x Jarvis 2>/dev/null || true
  $SUDO rm -rf "$TARGET/Jarvis.app"
  $SUDO cp -R "$APP" "$TARGET/Jarvis.app"
  # Avoid two copies: remove the one in the other location when we can.
  if [[ "$TARGET" == /Applications ]]; then
    rm -rf "$HOME/Applications/Jarvis.app"
  elif [[ -d /Applications/Jarvis.app ]]; then
    echo "⚠️  An older copy remains in /Applications (admin rights needed to remove it)."
  fi
  open "$TARGET/Jarvis.app"
  echo "▶ installed and launched $TARGET/Jarvis.app"
fi
