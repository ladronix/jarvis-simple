# Shared by scripts/build.sh and scripts/package.sh. Source it from the repository root.

# Generate Jarvis.xcodeproj and pin its packages to Core/Package.resolved, the one committed
# resolution. xcodebuild then runs with XCODE_PIN_FLAGS, so a build can never pick other
# versions than the ones reviewed in git.
prepare_project() {
  command -v xcodegen >/dev/null || { echo "xcodegen missing: brew install xcodegen"; exit 1; }
  xcodegen generate --quiet
  local resolved=Jarvis.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
  mkdir -p "$resolved"
  cp Core/Package.resolved "$resolved/Package.resolved"
}
XCODE_PIN_FLAGS=(-onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates)

# Signing identity, in order: $JARVIS_SIGN_IDENTITY, a "Developer ID Application" certificate,
# the local "Jarvis Dev" certificate (scripts/make-dev-cert.sh), ad-hoc ("-"). Identities are
# referenced by SHA-1: names with diacritics do not always match. Sets IDENTITY and IDENTITY_NAME.
identity_hash() {
  security find-identity -v -p codesigning 2>/dev/null | grep -F "\"$1" | head -1 | awk '{print $2}'
}
pick_identity() {
  IDENTITY="${JARVIS_SIGN_IDENTITY:-}"
  if [[ -z "$IDENTITY" ]]; then
    IDENTITY=$(identity_hash "Developer ID Application:")
    [[ -n "$IDENTITY" ]] || IDENTITY=$(identity_hash "Jarvis Dev")
    [[ -n "$IDENTITY" ]] || IDENTITY="-"
  fi
  if [[ "$IDENTITY" == "-" ]]; then
    IDENTITY_NAME="ad-hoc"
  else
    IDENTITY_NAME=$(security find-identity -v -p codesigning 2>/dev/null | grep -F -- "$IDENTITY" | head -1 | sed -E 's/.*"(.*)".*/\1/')
    [[ -n "$IDENTITY_NAME" ]] || IDENTITY_NAME="$IDENTITY"
  fi
}

# Build the Jarvis scheme ad-hoc (Xcode only signs with a configured team); callers re-sign.
# Usage: xcode_build <Debug|Release>; prints errors and fails when the build fails.
xcode_build() {
  local config="$1" log
  log=$(mktemp)
  xcodebuild -project Jarvis.xcodeproj -scheme Jarvis -configuration "$config" \
    -derivedDataPath "$PWD/DerivedData" -destination 'platform=macOS' "${XCODE_PIN_FLAGS[@]}" \
    CODE_SIGN_IDENTITY="-" DEVELOPMENT_TEAM="${JARVIS_TEAM:-}" \
    build >"$log" 2>&1 || true
  grep -E "error:|warning: .*(App|Core/Sources)/|BUILD (SUCCEEDED|FAILED)" "$log" | grep -vE "DVTPlugIn|IDESimulator" || true
  grep -q "BUILD SUCCEEDED" "$log" || { echo "build failed (see $log)"; exit 1; }
  rm -f "$log"
}
