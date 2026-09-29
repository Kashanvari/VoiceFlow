#!/bin/zsh
# Builds VoiceFlow.
#
#   ./build.sh            builds and installs ~/Applications/VoiceFlow.app for this Mac. The app keeps its models,
#                         history and logs in this folder and uses llama.cpp from Homebrew (scripts/setup.sh).
#   ./build.sh --release  builds the ready-made app for the GitHub release: dist/VoiceFlow-<version>-macOS-arm64.zip.
#                         It carries its own copy of llama.cpp, downloads the models on first launch into
#                         ~/Library/Application Support/VoiceFlow, and is signed ad-hoc (no personal certificate,
#                         so no personal details end up inside a public download).
#
# Signing of the local build: macOS remembers Accessibility and Microphone permissions by the app's signature. The
# personal self-signed certificate "VoiceFlow Developer" (Keychain Access, Code Signing type; see README) gives every
# build the same signature, so permissions survive rebuilds. Without it the app is signed ad-hoc, and each rebuild
# silently breaks both permissions (switch VoiceFlow off and on in Privacy & Security). The author's certificate
# was created 2026-09-29 and is valid until 2027-09-29; renew it the same way, with the same name.
set -e
cd "$(dirname "$0")"

VERSION=1.1.0
# The official llama.cpp build bundled into the release app, pinned and checked against GitHub's published SHA-256.
LLAMA_BUILD=b11146
LLAMA_SHA256=1ad3f9eff80edb9dbef4259ad564d1720612ef7eea48fa4afed0e54f5f3d5711

RELEASE=0
[[ $1 == --release ]] && RELEASE=1

swift build -c release --product VoiceFlow

if (( RELEASE )); then
    APP=dist/VoiceFlow.app
    BUNDLE_ID=io.github.kashanvari.voiceflow
else
    APP=~/Applications/VoiceFlow.app
    BUNDLE_ID=com.kash.voiceflow
    osascript -e "quit app id \"$BUNDLE_ID\"" 2>/dev/null || true
fi
BUILD_NUMBER=$(git rev-parse --short HEAD 2>/dev/null || echo dev)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/VoiceFlow "$APP/Contents/MacOS/VoiceFlow"
cp Resources/AppIcon.icns Resources/MenuBarIcon.png Resources/MenuBarIcon@2x.png "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleName</key><string>VoiceFlow</string>
    <key>CFBundleDisplayName</key><string>VoiceFlow</string>
    <key>CFBundleExecutable</key><string>VoiceFlow</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSArchitecturePriority</key><array><string>arm64</string></array>
    <key>NSHumanReadableCopyright</key><string>MIT licence. Runs entirely on this Mac.</string>
    <key>NSMicrophoneUsageDescription</key><string>VoiceFlow listens while you hold the dictation key and turns your speech into text on this Mac.</string>
</dict>
</plist>
PLIST

if (( ! RELEASE )); then
    # Tell the app where its models, history and logs are: this folder.
    plutil -insert VFProjectFolder -string "$PWD" "$APP/Contents/Info.plist"

    IDENTITY="VoiceFlow Developer"
    if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
        codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
        echo "Signed with \"$IDENTITY\" (permissions carry over)."
    else
        codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
        echo "WARNING: certificate \"$IDENTITY\" not found; signed ad-hoc. Re-grant Accessibility and Microphone."
    fi
    echo "Installed $APP"
    exit 0
fi

# ---- Release: bundle llama.cpp, licences, sign, zip ----
mkdir -p vendor
TARBALL=vendor/llama-$LLAMA_BUILD-bin-macos-arm64.tar.gz
if [[ ! -f $TARBALL ]]; then
    echo "Downloading llama.cpp $LLAMA_BUILD (official build, about 11 MB)…"
    curl -L --fail --progress-bar -o "$TARBALL.part" \
        "https://github.com/ggml-org/llama.cpp/releases/download/$LLAMA_BUILD/llama-$LLAMA_BUILD-bin-macos-arm64.tar.gz"
    mv "$TARBALL.part" "$TARBALL"
fi
echo "$LLAMA_SHA256  $TARBALL" | shasum -a 256 -c - >/dev/null || { echo "llama.cpp download does not match its checksum"; exit 1; }
rm -rf vendor/llama && mkdir -p vendor/llama && tar -xzf "$TARBALL" -C vendor/llama
SRC=vendor/llama/llama-$LLAMA_BUILD

HELPERS="$APP/Contents/Helpers/llama"
mkdir -p "$HELPERS"
cp -L "$SRC/llama-server" "$HELPERS/"
# Copy every library llama-server needs (found through @rpath, which points next to the program).
pending=("$HELPERS/llama-server")
while (( ${#pending} )); do
    file=${pending[1]}; pending=("${(@)pending[2,-1]}")
    for lib in $(otool -L "$file" | grep -o '@rpath/[^ ]*' | sed 's#@rpath/##'); do
        if [[ ! -f $HELPERS/$lib ]]; then
            cp -L "$SRC/$lib" "$HELPERS/$lib"
            pending+=("$HELPERS/$lib")
        fi
    done
done
cp "$SRC/LICENSE" "$APP/Contents/Resources/llama.cpp-LICENSE.txt"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"

# Ad-hoc signatures, inside out: libraries, the helper program, then the app.
for f in "$HELPERS"/*.dylib; do codesign --force --sign - "$f"; done
codesign --force --sign - "$HELPERS/llama-server"
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
codesign --verify --deep --strict "$APP"

ZIP=dist/VoiceFlow-$VERSION-macOS-arm64.zip
rm -f "$ZIP" "$ZIP.sha256"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
(cd dist && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
echo "Built $ZIP ($(du -h "$ZIP" | cut -f1)); helper libraries: $(ls "$HELPERS" | wc -l | tr -d ' ') files"
