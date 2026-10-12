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
#   REC_VERSION        version string for Info.plist (default 0.0.0-dev)
#   REC_APP_DIR        where to put the .app (default build)
#   REC_UNIVERSAL=1    build arm64 + x86_64 instead of only this machine's arch
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${REC_APP_DIR:-build}/Recorder.app"
VERSION="${REC_VERSION:-0.0.0-dev}"
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

if [ "${REC_UNIVERSAL:-0}" = "1" ]; then
  # Two passes and a lipo: `swift build --arch a --arch b` needs Xcode's xcbuild, which the Command Line Tools lack.
  echo "==> swift build (arm64 + x86_64)"
  swift build -c release --triple arm64-apple-macosx15.0 --scratch-path .build/arm64
  swift build -c release --triple x86_64-apple-macosx15.0 --scratch-path .build/x86
  mkdir -p .build/universal
  lipo -create -output .build/universal/Recorder \
    .build/arm64/arm64-apple-macosx/release/Recorder \
    .build/x86/x86_64-apple-macosx/release/Recorder
  BIN=".build/universal/Recorder"
else
  echo "==> swift build"
  swift build -c release
  BIN=".build/release/Recorder"
fi

echo "==> assembling $APP (version $VERSION)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Recorder"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>Recorder</string>
  <key>CFBundleExecutable</key>        <string>Recorder</string>
  <key>CFBundleIdentifier</key>        <string>com.topherhunt.recorder</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key>           <string>$VERSION</string>
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
