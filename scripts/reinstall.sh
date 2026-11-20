#!/bin/bash
# Rebuild & reinstall Fit3BridgeFree on the connected iPhone.
#
# Why: a free Apple ID signs apps for only 7 days, then the app refuses to open.
# Run this when that happens, or after changing any code.
#
# Usage:
#   scripts/reinstall.sh            # auto-detects the connected iPhone
#   scripts/reinstall.sh <UDID>     # or pass an explicit device UDID
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="com.fit3bridgefree.ios"   # keep in sync with project.yml

# 1. Make sure the full Xcode is used (not the Command Line Tools).
if /usr/bin/xcode-select -p | grep -q CommandLineTools; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi
if ! xcodebuild -version >/dev/null 2>&1; then
  echo "❌ Xcode not found — install it from the App Store." >&2
  exit 1
fi

# 2. Find the iPhone (plugged in + unlocked + trusted).
DEVICE="${1:-}"
if [ -z "$DEVICE" ]; then
  DEVICE=$(xcrun devicectl list devices 2>/dev/null \
    | grep -E '\(UDID\)' | grep connected | head -1 \
    | grep -oE '[0-9A-F]{8}-[0-9A-F]{16}')
fi
if [ -z "$DEVICE" ]; then
  echo "❌ No connected iPhone found. Plug it in, unlock it, tap Trust, then re-run." >&2
  exit 1
fi
echo "📱 Device: $DEVICE"

# 3. Build + sign (refreshes the free-team provisioning profile automatically).
echo "🔨 Building…"
xcodebuild -project Fit3BridgeFree.xcodeproj -scheme Fit3BridgeFree -configuration Debug \
  -destination "platform=iOS,id=$DEVICE" \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  build

# 4. Locate the built .app.
BUILD_DIR=$(xcodebuild -project Fit3BridgeFree.xcodeproj -scheme Fit3BridgeFree -configuration Debug \
  -showBuildSettings 2>/dev/null | awk -F' = ' '/ TARGET_BUILD_DIR =/{print $2; exit}')
APP="$BUILD_DIR/Fit3BridgeFree.app"
if [ ! -d "$APP" ]; then
  echo "❌ Built app not found at: $APP" >&2
  exit 1
fi

# 5. Install & launch.
echo "📲 Installing…"
xcrun devicectl device install app --device "$DEVICE" "$APP"
echo "🚀 Launching…"
xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE_ID" || true

echo ""
echo "✅ Done. If the app won't open, trust the developer certificate once:"
echo "   iPhone → Settings → General → VPN & Device Management → Apple Development: … → Trust"
