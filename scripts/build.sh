#!/usr/bin/env zsh
# Build Jarvis.app (Debug by default). Usage: scripts/build.sh [Debug|Release] [--open]
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/common.sh
CONFIG="${1:-Debug}"
APP="$PWD/DerivedData/Build/Products/$CONFIG/Jarvis.app"

prepare_project
# Same identity as installed releases, so they share the Microphone and Accessibility grants.
pick_identity
rm -rf "$APP"
xcode_build "$CONFIG"
[[ -d "$APP" ]] || { echo "build produced no app"; exit 1; }

# Deep re-sign so embedded code carries the same identity (stable TCC grants).
if ! codesign --force --deep --options runtime --sign "$IDENTITY" --entitlements App/Jarvis.entitlements "$APP" 2>/dev/null; then
  echo "⚠️  signing with \"$IDENTITY_NAME\" failed; the app stays ad-hoc signed and macOS will ask for permissions again."
  echo "   Run scripts/make-dev-cert.sh once to create the local certificate."
fi
AUTHORITY=$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)
echo "signed with: ${AUTHORITY:-ad-hoc}"
echo "built: $APP"
if [[ "${2:-}" == "--open" ]]; then
  pkill -x Jarvis 2>/dev/null || true
  open "$APP"
fi
