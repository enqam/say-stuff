#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_PATH="$ROOT_DIR/.derivedData-dev"
INSTALL_PATH="${SAYSTUFF_DEV_APP_PATH:-$HOME/Applications/SayStuff Dev.app}"
APP_SOURCE="$DERIVED_DATA_PATH/Build/Products/Debug/SayStuff.app"

find_signing_identities() {
  security find-identity -v -p codesigning |
    sed -n 's/.*"\(Apple Development: .*([A-Z0-9][A-Z0-9]*)\)".*/\1/p' |
    awk '!seen[$0]++'
}

if [[ -n "${CODE_SIGN_IDENTITY:-}" ]]; then
  SIGNING_IDENTITIES=("$CODE_SIGN_IDENTITY")
else
  SIGNING_IDENTITIES=()
  while IFS= read -r IDENTITY; do
    SIGNING_IDENTITIES+=("$IDENTITY")
  done < <(find_signing_identities)
fi

if [[ "${#SIGNING_IDENTITIES[@]}" -eq 0 ]]; then
  cat >&2 <<'EOF'
No Apple Development signing identity was found.

Install/sign in to your Apple developer account in Xcode, or run with:
  CODE_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" scripts/dev-run.sh
EOF
  exit 1
fi

cd "$ROOT_DIR"

xcodebuild \
  -project SayStuff.xcodeproj \
  -scheme SayStuff \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  build

mkdir -p "$(dirname "$INSTALL_PATH")"
rm -rf "$INSTALL_PATH"
ditto "$APP_SOURCE" "$INSTALL_PATH"

SIGN_OK=0
for IDENTITY in "${SIGNING_IDENTITIES[@]}"; do
  echo "Signing with: $IDENTITY"
  if codesign \
    --force \
    --deep \
    --sign "$IDENTITY" \
    --entitlements "$ROOT_DIR/SayStuff/SayStuff.entitlements" \
    "$INSTALL_PATH"; then
    SIGN_OK=1
    break
  fi
done

if [[ "$SIGN_OK" != "1" ]]; then
  echo "Could not sign with any Apple Development identity." >&2
  exit 1
fi

codesign -dv "$INSTALL_PATH" 2>&1 | sed -n 's/^TeamIdentifier=/Signed TeamIdentifier=/p'
echo "Installed: $INSTALL_PATH"

pkill -x SayStuff 2>/dev/null || true

if [[ "${SAYSTUFF_SKIP_OPEN:-0}" != "1" ]]; then
  open -n "$INSTALL_PATH"
fi
