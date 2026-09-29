# Models

`scripts/setup.sh` downloads these here (about 1.3 GB). They are not stored in git. The app also downloads the
speech model by itself if it is missing.

| Folder / file | What | Size | Licence | Source |
|---|---|---|---|---|
| `parakeet-tdt-0.6b-v2-coreml/` | Speech to text, English | 443 MB | CC-BY-4.0 | huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml |
| `cleanup/speakoflow-mini-Q8_0.gguf` | Text clean-up | 834 MB | Apache-2.0 | huggingface.co/SpeakoFlow/speakoflow-mini |

Optional, only for re-running `experiments/cleanup-model-test`: `cleanup/bitvoice-qwen3-0.6b-ft.gguf` from
huggingface.co/dhanr4j/bitvoice-dictation (`gguf/qwen3-0.6b-ft.gguf`, Apache-2.0).

Keep the project folder out of iCloud-synced places (Desktop, Documents): iCloud can remove large files from the
Mac to save space, and the app then can't find its models.
