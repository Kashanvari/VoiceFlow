#!/bin/zsh
# Builds VoiceFlow and installs it as ~/Applications/VoiceFlow.app.
#
# Signing: macOS remembers Accessibility and Microphone permissions by the app's signature. The personal
# self-signed certificate "VoiceFlow Developer" (Keychain Access, created 2026-09-29, valid until 2027-09-29)
# gives every build the same signature, so permissions survive rebuilds. Without it the app is signed ad-hoc,
# and each rebuild silently breaks both permissions (switch VoiceFlow off and on in Privacy & Security).
# To renew: Keychain Access → Certificate Assistant → Create a Certificate…, same name, type Code Signing,
# then grant the two permissions once more.
set -e
cd "$(dirname "$0")"

swift build -c release --product VoiceFlow

APP=~/Applications/VoiceFlow.app
VERSION=$(git describe --tags --always 2>/dev/null || echo dev)
osascript -e 'quit app id "com.kash.voiceflow"' 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/VoiceFlow "$APP/Contents/MacOS/VoiceFlow"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.kash.voiceflow</string>
    <key>CFBundleName</key><string>VoiceFlow</string>
    <key>CFBundleDisplayName</key><string>VoiceFlow</string>
    <key>CFBundleExecutable</key><string>VoiceFlow</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHumanReadableCopyright</key><string>Runs entirely on this Mac.</string>
    <key>NSMicrophoneUsageDescription</key><string>VoiceFlow listens while you hold the fn key and turns your speech into text on this Mac.</string>
</dict>
</plist>
PLIST

# Tell the app where its models, history and logs are: this folder.
plutil -insert VFProjectFolder -string "$PWD" "$APP/Contents/Info.plist"

IDENTITY="VoiceFlow Developer"
if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
    codesign --force --sign "$IDENTITY" --identifier com.kash.voiceflow "$APP"
    echo "Signed with \"$IDENTITY\" (permissions carry over)."
else
    codesign --force --sign - --identifier com.kash.voiceflow "$APP"
    echo "WARNING: certificate \"$IDENTITY\" not found; signed ad-hoc. Re-grant Accessibility and Microphone."
fi
echo "Installed $APP"
