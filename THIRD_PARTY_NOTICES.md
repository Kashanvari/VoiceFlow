# Third-party notices

VoiceFlow's own code is MIT-licensed (see `LICENSE`). It builds on the following work.

## Code

- **FluidAudio** (Apache-2.0), FluidInference: https://github.com/FluidInference/FluidAudio
  Runs the Parakeet speech model on the Neural Engine. Fetched by Swift Package Manager.
- **super-voice-assistant** (MIT License with exclusions), Copyright (c) 2025 Super Voice Assistant Contributors:
  https://github.com/ykdojo/super-voice-assistant
  `Sources/VoiceFlow/FnKeyMonitor.swift` is adapted from its fn-key monitor. Its licence excludes the project's
  name, branding and image files; VoiceFlow uses none of them.
  The MIT permission notice for that code: Permission is hereby granted, free of charge, to any person obtaining
  a copy of this software and associated documentation files (the "Software"), to deal in the Software without
  restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute,
  sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do
  so, subject to the following conditions: The above copyright notice and this permission notice shall be
  included in all copies or substantial portions of the Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT
  WARRANTY OF ANY KIND.
- **llama.cpp** (MIT), ggml-org: https://github.com/ggml-org/llama.cpp
  Not bundled: installed separately with Homebrew and run as a separate program.

## Models (downloaded by `scripts/setup.sh`, not included in this repository)

- **NVIDIA Parakeet TDT 0.6b v2** (CC-BY-4.0), NVIDIA, converted to Core ML by FluidInference:
  https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml
  (original: https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2)
- **SpeakoFlow Mini 0.8B** (Apache-2.0), SpeakoFlow, fine-tuned from Qwen3.5-0.8B (Apache-2.0):
  https://huggingface.co/SpeakoFlow/speakoflow-mini
  The clean-up system prompt in `Sources/VoiceFlowCore/Cleaner.swift` is the one the model was trained with,
  as published on its model card.
