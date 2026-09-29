#!/bin/zsh
# One-time setup for VoiceFlow: checks this Mac, installs llama.cpp (runs the clean-up model) and downloads the
# two AI models into models/ (about 1.3 GB). Safe to run again: it skips anything already in place.
#
#   ./scripts/setup.sh
set -e
cd "$(dirname "$0")/.."

say_step() { print -P "\n%B$1%b"; }
fail() { print -P "%F{red}$1%f"; exit 1; }

say_step "Checking this Mac"
[[ $(uname -m) == arm64 ]] || fail "VoiceFlow needs an Apple Silicon Mac (M1 or newer)."
major=$(sw_vers -productVersion | cut -d. -f1)
(( major >= 14 )) || fail "VoiceFlow needs macOS 14 Sonoma or newer (this Mac has $(sw_vers -productVersion))."
xcode-select -p >/dev/null 2>&1 || fail "Install Apple's Command Line Tools first:  xcode-select --install"
command -v brew >/dev/null || fail "Install Homebrew first, from https://brew.sh"
echo "OK: Apple Silicon, macOS $(sw_vers -productVersion), Command Line Tools, Homebrew."

say_step "Installing llama.cpp (runs the clean-up model on the GPU)"
if command -v llama-server >/dev/null; then echo "Already installed."; else brew install llama.cpp; fi

# Downloads are pinned to the exact model versions VoiceFlow 1.0 was tested with.
HF=https://huggingface.co

say_step "Downloading the clean-up model: SpeakoFlow Mini 0.8B (834 MB, Apache-2.0)"
mkdir -p models/cleanup
GGUF=models/cleanup/speakoflow-mini-Q8_0.gguf
if [[ -s $GGUF ]]; then
    echo "Already downloaded."
else
    curl -L --fail --progress-bar -o "$GGUF.part" \
        "$HF/SpeakoFlow/speakoflow-mini/resolve/835431771f72820251fe6c6b4b07f12b000e2647/SpeakoFlow-Mini-0.8B-Q8_0.gguf"
    mv "$GGUF.part" "$GGUF"
fi

say_step "Downloading the speech model: NVIDIA Parakeet TDT 0.6b v2 for Core ML (443 MB, CC-BY-4.0)"
REPO=FluidInference/parakeet-tdt-0.6b-v2-coreml
REV=ee09c569f73759e6d44c9bd16766f477b2b36d39
DEST=models/parakeet-tdt-0.6b-v2-coreml
if [[ -s $DEST/parakeet_vocab.json && -d $DEST/Encoder.mlmodelc ]]; then
    echo "Already downloaded."
else
    # Only the parts VoiceFlow loads; the repository also holds 2 GB of other variants.
    files=$(curl -s --fail "$HF/api/models/$REPO/tree/$REV?recursive=true" | /usr/bin/python3 -c '
import sys, json
wanted = ("Preprocessor.mlmodelc/", "Encoder.mlmodelc/", "Decoder.mlmodelc/", "JointDecision.mlmodelc/")
for f in json.load(sys.stdin):
    if f["type"] == "file" and (f["path"].startswith(wanted) or f["path"] in ("config.json", "parakeet_vocab.json")):
        print(f["path"])')
    [[ -n $files ]] || fail "Could not list the speech model files. Check the internet connection and try again."
    count=$(echo "$files" | wc -l | tr -d ' ')
    i=0
    for f in ${(f)files}; do
        i=$((i + 1))
        printf "\r  file %d of %d" $i $count
        mkdir -p "$DEST/$(dirname "$f")"
        curl -L --fail -s -o "$DEST/$f" "$HF/$REPO/resolve/$REV/$f"
    done
    echo
fi

say_step "Done. Next: build and install the app"
echo "  ./build.sh"
