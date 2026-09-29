# VoiceFlow

**Private, offline dictation for macOS.** Hold a key, speak, let go: your words appear wherever your cursor is,
already cleaned up. Speech recognition and clean-up both run on your Mac. No account, no subscription, no audio or
text ever leaves the computer.

Inspired by cloud dictation apps such as Wispr Flow, but local-first. VoiceFlow is an independent open-source
project and is not affiliated with Wispr.

| You say | VoiceFlow types |
|---|---|
| "Um, so I was thinking we could, uh, push the launch to next week" | So I was thinking we could push the launch to next week. |
| "Let's meet on Thursday, no, Friday at noon" | Let's meet on Friday at noon. |
| "The site is live now. Scratch that. The site will be live tonight" | The site will be live tonight. |
| "My email is sam at example dot com" | My email is sam@example.com. |
| "Thanks for your help today. New paragraph. I'll send the invoice tomorrow" | Thanks for your help today.<br><br>I'll send the invoice tomorrow. |
| "For tomorrow, bullet one, call the supplier. Bullet two, send the invoice" | For tomorrow,<br>- Call the supplier<br>- Send the invoice |
| "What is 17 times 23" | What is 17 times 23? *(typed, never answered)* |

## Features

- **Hold to talk** with the fn (🌐) key, or Right Option / Right Command / Right Control on keyboards without fn.
  **Double-tap** for hands-free, **Esc** to cancel.
- **Fast, accurate speech to text** with NVIDIA Parakeet TDT 0.6b v2 on the Neural Engine: about 30–60 ms for a
  sentence.
- **AI clean-up** with SpeakoFlow Mini, a small model trained for exactly this job: removes filler words, applies
  your corrections ("no, Friday", "scratch that"), spoken punctuation ("new paragraph"), emails and bullet lists,
  and leaves sentences that were already right untouched. About 0.1–0.4 s per sentence.
- **Safety net:** when the clean-up model's answer looks wrong (it answered your question, added words, or lost
  most of a long passage), VoiceFlow types your own words instead.
- **Dictionary:** fix words it mishears ("git hub" → "GitHub") or make shortcuts.
- **Learns from your corrections:** fix a wrong word right where VoiceFlow typed it, and it writes it correctly
  from then on. The **Corrections** page lists every word you fixed.
- **Works in any app** that accepts paste. Your clipboard is put back afterwards.
- **History** with search and copy, plus simple stats (words, words per minute, time saved vs typing).
- **Microphone handling** for AirPods and Bluetooth headsets (see Troubleshooting), and it skips virtual
  "microphones" such as Microsoft Teams Audio that carry no voice.

## Download (easiest)

For a Mac with **Apple Silicon** (M1 or newer) and **macOS 14 Sonoma** or newer. English speech only for now.

1. Download **VoiceFlow-1.1.0-macOS-arm64.zip** from the
   [latest release](https://github.com/Kashanvari/VoiceFlow/releases/latest) (12 MB).
2. Double-click the zip, then drag **VoiceFlow** into your **Applications** folder.
3. Open VoiceFlow. The first time, macOS says it can't check the app for malicious software and won't open it,
   because VoiceFlow isn't notarized by Apple (that needs a paid Apple developer account). Click **Done**, then go to
   **System Settings → Privacy & Security**, scroll down to *"VoiceFlow" was blocked*, click **Open Anyway**, and
   confirm with your password. You only do this once per version.
4. On first launch VoiceFlow downloads its two AI models (about 1.3 GB, once) into
   `~/Library/Application Support/VoiceFlow`. The window shows the progress. After that it works offline.
5. Follow **First launch** below (microphone, Accessibility, and the 🌐 key setting).

When you install a newer version, macOS may forget the Microphone and Accessibility permissions: switch VoiceFlow
off and on again in Privacy & Security if it stops hearing you or stops reacting to the key.

## Build from source

Requirements:
- A Mac with **Apple Silicon** (M1 or newer) and **macOS 14 Sonoma** or newer
- **Apple's Command Line Tools** (`xcode-select --install`); the full Xcode app is not needed
- **Homebrew** (https://brew.sh), used to install llama.cpp
- About **2 GB** of free space (1.3 GB of models plus the build)

```bash
git clone https://github.com/Kashanvari/VoiceFlow.git ~/Projects/VoiceFlow
cd ~/Projects/VoiceFlow
./scripts/setup.sh      # checks your Mac, installs llama.cpp, downloads the two models (about 1.3 GB)
./build.sh              # builds VoiceFlow and installs it in ~/Applications
open ~/Applications/VoiceFlow.app
```

Keep the folder out of iCloud-synced places (Desktop, Documents). An app built from source keeps its models, history
and logs inside this folder, and iCloud can remove large files from the Mac to save space.

`./build.sh --release` builds the ready-made download instead: it bundles the official llama.cpp build (pinned and
checked by SHA-256), signs the app ad-hoc and writes `dist/VoiceFlow-<version>-macOS-arm64.zip`.

### Recommended: a free personal signing certificate

macOS remembers the Microphone and Accessibility permissions by the app's signature. Without a certificate every
build gets a new throwaway signature, so after each rebuild the permissions quietly stop working (the microphone
records silence) until you switch VoiceFlow off and on again in System Settings. A personal certificate fixes this
for good. It takes two minutes and stays on your Mac:

1. Open Keychain Access. On recent macOS versions it is hidden: run
   `open "/System/Library/CoreServices/Applications/Keychain Access.app"` and choose **Open Keychain Access** if
   macOS suggests the Passwords app instead.
2. Menu **Keychain Access → Certificate Assistant → Create a Certificate…**
3. Name: `VoiceFlow Developer` · Identity Type: **Self Signed Root** · Certificate Type: **Code Signing** → **Create**.
4. Run `./build.sh` again. When macOS asks whether codesign may use the key, enter your password and click
   **Always Allow**.

`build.sh` uses the certificate automatically when it finds it, and falls back to ad-hoc signing otherwise.

## First launch

1. **Allow the microphone** when macOS asks.
2. **Allow Accessibility**: System Settings → Privacy & Security → Accessibility → switch on VoiceFlow. It needs
   this to notice the dictation key and to paste for you.
3. If you use the fn key: System Settings → Keyboard → **"Press 🌐 key to" → Do Nothing**. Otherwise tapping or
   double-tapping fn also opens the emoji picker. macOS handles that key before any app sees it, so VoiceFlow
   can't block it; it shows a reminder with a button to the right settings page until it's changed.
4. The first start takes about 45 seconds while macOS prepares the speech model for the Neural Engine. After that
   it starts in about a second.

Then click into any text box, hold fn, wait for the dot in the bubble to turn **red**, speak, and let go.

## Using it

| Action | What happens |
|---|---|
| Hold the key, speak, let go | Records while held, then types the cleaned-up text at the cursor |
| Double-tap the key | Hands-free: keeps recording until you tap the key again |
| **Esc** while recording | Cancels, nothing is typed |
| The key together with another key (fn+←, ⌥+e…) | Cancels, so normal shortcuts still work |

The bubble at the bottom of the screen shows a **grey dot** while the microphone starts and a **red dot** when it
is listening. Bluetooth microphones take a moment to wake up, so start talking when the dot is red.

**The window** (Dock icon, or the VoiceFlow logo in the menu bar → Open VoiceFlow):
- **Home:** status, stats and your searchable history, with "copy" and "copy without clean-up" on each entry.
- **Dictionary:** "when VoiceFlow hears X, write Y". Whole words, any upper or lower case, applied before the
  AI clean-up. A shortcut fires every time you say its words, so choose words you wouldn't say by accident.
- **Corrections:** the words you fixed after dictating, whether each was learned, and how often VoiceFlow has
  written it right for you since. **Forget** takes a word out of the Dictionary; **Learn** adds one that wasn't.
- **Settings:** dictation key, AI clean-up, sounds, microphone, keep-the-mic-ready, permissions, open at login,
  clear history.

Closing the window keeps VoiceFlow running in the menu bar, so the dictation key keeps working.

### Learning from your corrections

After a dictation, VoiceFlow watches that text box for a few minutes. If you fix a word it got wrong ("mark" →
"Marc"), it notices and adds the fix to your Dictionary, so the next dictation gets it right. The watch ends when
you dictate again, when the text is gone (a chat message was sent), 30 seconds after your last edit, or after
5 minutes.

- **Learned:** a word that isn't ordinary English, like a name or a mis-spelling ("wisper" → "Wispr"), a name
  written as an everyday word ("cloud" → "Claude"), and joined-up or capitalised spelling ("open ai" → "OpenAI",
  "github" → "GitHub").
- **Listed, not learned:** edits between two everyday words ("meeting" → "meetings", "to" → "two"), because a
  Dictionary entry changes that word in every dictation. Press **Learn** if one is always wrong.
- **Ignored:** words you add or delete, rewording ("big" → "large"), punctuation, and capitals at the start of a
  sentence.
- **Changed your mind?** Change a learned word back and VoiceFlow forgets it.

It works in apps that share their text box through Accessibility, which includes the Claude app and TextEdit;
most web browsers don't yet. The text is read on your Mac, only held in memory while watching, and never saved:
only the corrected word pairs are kept, in `data/corrections.json`. Switch it off in Settings → "Learn from my
corrections".

## How it works

```
hold key ─► microphone (AVAudioEngine on a background queue, converted to 16 kHz mono)
let go  ─► Parakeet TDT 0.6b v2 via FluidAudio (Neural Engine)            models/parakeet-tdt-0.6b-v2-coreml
        ─► Dictionary replacements                                         data/dictionary.json
        ─► Rules: drop "um", "uh", "erm"                                    Sources/VoiceFlowCore/Rules.swift
        ─► SpeakoFlow Mini 0.8B in llama.cpp's llama-server (GPU)          models/cleanup
           in pieces of about 120 words, each checked by the safety net
        ─► final full stop or question mark
        ─► paste: clipboard + ⌘V, then your previous clipboard is restored
```

- VoiceFlow starts `llama-server` itself on `127.0.0.1` (local only; port 8790 for a build from source, 8792 for the
  downloaded app) and stops it when it quits. The downloaded
  app carries its own copy of llama.cpp; a build from source uses Homebrew's. If llama.cpp or the clean-up model is
  missing, VoiceFlow still works with the rules-only clean-up.
- History is stored as text only (no audio) in `data/history.jsonl`, corrections in `data/corrections.json`, with
  logs in `logs/`: inside the project folder
  for a build from source, or in `~/Library/Application Support/VoiceFlow` for the downloaded app.
- Nothing is sent over the network, apart from the one-time model downloads from Hugging Face.

## Troubleshooting

| Problem | Fix |
|---|---|
| Tapping fn opens the emoji picker | System Settings → Keyboard → "Press 🌐 key to" → Do Nothing (VoiceFlow → Home has a button to that page) |
| Nothing happens when I hold the key | Accessibility permission: switch VoiceFlow off and on in Privacy & Security → Accessibility |
| The bubble says "Didn't catch that" every time | The Microphone permission belongs to an older build: switch VoiceFlow off and on in Privacy & Security → Microphone (or set up the signing certificate above) |
| "No real microphone" | Mac minis and Mac Studios have no built-in mic. Connect AirPods, a headset or a USB microphone |
| The first words get cut off with AirPods | Wait for the red dot. Keep "Keep the microphone ready" on (Settings) so the next dictation starts instantly |
| Music sounds like a phone call after dictating | That's AirPods in call mode while the mic is kept ready (30 s). Switch off "Keep the microphone ready" in Settings |
| "Clean-up: Not running (rules only)" | Downloaded app: quit and reopen it (it starts the model download again). From source: run `./scripts/setup.sh`. Details in `logs/llama-server.log` |
| macOS won't open the downloaded app | System Settings → Privacy & Security → *"VoiceFlow" was blocked* → Open Anyway |

## Development

```bash
swift run -c release VoiceFlowCheck --rules   # instant tests: rules, dictionary, splitting, safety net, learning
swift run -c release VoiceFlowCheck --cases   # 32 test sentences through the real clean-up model
swift run -c release VoiceFlowCheck           # speaks test sentences with macOS `say` and runs the whole pipeline
open ~/Applications/VoiceFlow.app --args --record-test   # records three clips back to back and logs timings
open -n ~/Applications/VoiceFlow.app --args --learn-test  # with a TextEdit document open: paste, correct, learn (dry run)
open -n ~/Applications/VoiceFlow.app --args --ax-probe    # which open apps share their focused text box (no text logged)
```

| Folder | What |
|---|---|
| `Sources/VoiceFlowCore` | Speech to text, clean-up, rules, dictionary, learning from corrections, audio conversion |
| `Sources/VoiceFlow` | The app: window, menu bar, dictation key, recorder, paste, history, watching for corrections |
| `Sources/VFObjC` | Turns Core Audio exceptions into errors instead of crashes |
| `Sources/VoiceFlowCheck` | Command-line tests |
| `experiments/cleanup-model-test` | The comparison that picked SpeakoFlow Mini over BitVoice (28 vs 16 of 32) |
| `scripts/` | `setup.sh`, and `make_icon.swift`, which draws the app icon and the menu-bar icon from `Resources/Logo.png` |

Known limitations in 1.0: English only; spoken numbered lists ("number one, …") are not turned into lists; no
per-app tone or context awareness yet.

## Licence

VoiceFlow is MIT-licensed (see `LICENSE`). The models and libraries it uses have their own licences, listed in
`THIRD_PARTY_NOTICES.md`: Parakeet TDT 0.6b v2 is CC-BY-4.0 (NVIDIA), SpeakoFlow Mini is Apache-2.0, FluidAudio is
Apache-2.0, llama.cpp is MIT.
