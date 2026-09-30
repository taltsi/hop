#!/bin/bash
# Usage: ./build.sh            -> builds build/Hop.app
#        ./build.sh install    -> also installs to ~/Applications and (re)launches it
#
# Signing: uses the local certificate from scripts/setup-signing.sh if present, so the
# Accessibility permission survives rebuilds. Otherwise falls back to ad-hoc signing
# (the permission then has to be re-granted after every build). HOP_SIGN_IDENTITY overrides.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/Hop.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Hop "$APP/Contents/MacOS/Hop"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
SIGN_KEYCHAIN="$HOME/Library/Keychains/hop-signing.keychain-db"
if [[ -n "${HOP_SIGN_IDENTITY:-}" ]]; then
    codesign --force --sign "$HOP_SIGN_IDENTITY" "$APP"
elif [[ -f "$SIGN_KEYCHAIN" ]]; then
    security unlock-keychain -p hop-local-signing "$SIGN_KEYCHAIN"
    # Sign by hash: the self-signed certificate isn't trusted, so lookup by name fails.
    HASH=$(security find-certificate -c "Hop Local Signing" -Z "$SIGN_KEYCHAIN" | awk '/SHA-1/ { print $3; exit }')
    codesign --force --sign "$HASH" "$APP"
else
    echo "warning: ad-hoc signing; run scripts/setup-signing.sh to keep permissions across builds"
    codesign --force --sign - "$APP"
fi
echo "Built $APP"

if [[ "${1:-}" == "install" ]]; then
    pkill -x Hop || true
    mkdir -p ~/Applications
    rm -rf ~/Applications/Hop.app
    cp -R "$APP" ~/Applications/
    open ~/Applications/Hop.app
    echo "Installed and launched ~/Applications/Hop.app"
fi
