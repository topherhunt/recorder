#!/bin/bash
# Builds build/Recorder.app. Run with: bash scripts/build.sh
#
# Signing: macOS pins the Screen Recording and Microphone grants to the code
# signature. Ad-hoc signing changes identity every build, so you'd re-grant each
# time. This uses the self-signed "Activity Monitor Dev" cert from the
# activity-monitor project (any self-signed code signing cert works).
#
# Environment:
#   REC_SIGN_IDENTITY  certificate common name, or "-" to force ad-hoc signing
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Recorder.app"
CERT="${REC_SIGN_IDENTITY:-Activity Monitor Dev}"

if [ "$CERT" = "-" ]; then
  IDENTITY="-"
else
  # By fingerprint, lowest first: duplicate common names make codesign refuse a name match.
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' -v n="$CERT" '$2 == n { print $1 }' \
    | awk '{ print $2 }' | sort | head -1)"
  if [ -z "$IDENTITY" ]; then
    IDENTITY="-"
    echo "!! no '$CERT' certificate found; signing ad-hoc. Permissions will reset on every rebuild."
  fi
fi

echo "==> swift build"
swift build -c release

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Recorder "$APP/Contents/MacOS/Recorder"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>Recorder</string>
  <key>CFBundleExecutable</key>        <string>Recorder</string>
  <key>CFBundleIdentifier</key>        <string>com.topherhunt.recorder</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key>           <string>1</string>
  <key>LSMinimumSystemVersion</key>    <string>15.0</string>
  <key>LSUIElement</key>               <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Recorder captures your microphone when "Record microphone" is on.</string>
</dict>
</plist>
PLIST

echo "==> signing with identity: $IDENTITY"
codesign --force --sign "$IDENTITY" --timestamp=none "$APP"

echo
echo "Built $APP -- run it with: open $APP"
