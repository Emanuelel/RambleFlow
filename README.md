# RambleFlow

**Local voice typing for macOS.** Hold Fn, speak, and release to turn your words into text at the cursor. RambleFlow runs speech recognition and transcript cleanup on your Mac.

[Install](#install) · [Features](#features) · [The recipe](#the-recipe) · [Quick start](#quick-start) · [Changelog](CHANGELOG.md)

## Install

| Platform | Availability |
| --- | --- |
| macOS on Apple silicon | [Build from source](#quick-start). The disk image and Homebrew cask are pending. |

See the [release checklist](RELEASE.md) for the planned installer and its runtime.

## Features

- **Dictate into other apps.** Use the global shortcut to insert text into the focused field, or try dictation in the built-in Scratchpad.
- **Clean up transcripts locally.** Parakeet recognizes speech, and QVAC runs the cleanup model on your Mac.
- **Save custom vocabulary.** Add names and terms you use often. The optional fast recognizer can use them during transcription.
- **Open from the Dock or menu bar.** Click the app icon to reopen the main window, or use the waveform in the menu bar.

## The recipe

1. **Hear.** NVIDIA Parakeet turns microphone audio into text on your Mac. The source build uses QVAC for recognition. The optional fast setup uses the local Phonon sidecar.
2. **Clean up.** QVAC runs a local language model to fix punctuation and remove false starts while preserving what you meant. The planned fast installer pairs it with Broad1291 + Literal192, our fine-tuned Qwen3 1.7B refiner. The source build uses the compatible GGUF you supply.
3. **Work ahead.** In the fast setup, recognition and cleanup can start before you release the shortcut. When the final transcript matches the preview or only needs a supported punctuation update, RambleFlow can reuse the work.
4. **Insert.** With Accessibility permission, RambleFlow can put the result into the focused text field. The Scratchpad lets you try the same workflow inside the app.

## Quick start

The source build targets Apple silicon (arm64) and macOS 14 or later. An earlier release candidate was checked on an M1 Pro running macOS 26.5.1. The deployment target is macOS 14. Compatibility testing on macOS 14 is pending. Intel Macs are outside the build target.

Install the Apple command-line developer tools, Python 3, and Node.js with npm. The supported Node ranges are 22.23 or later in the 22.x series, or 24.9 or later. If the Apple tools are missing, run `xcode-select --install`.

Clone the repository and enter the checkout before running the build commands below.

```sh
git clone https://github.com/Emanuelel/RambleFlow.git
cd RambleFlow
```

Use compatible GGUF refiner weights. The app uses a chat-style cleanup prompt and supports an optional LoRA adapter trained against the same base weights.

For a starter model, use [Qwen3-1.7B-Q4_0.gguf](https://huggingface.co/unsloth/Qwen3-1.7B-GGUF/blob/d7f544eead698dbd1f15126ef60b45a1e1933222/Qwen3-1.7B-Q4_0.gguf), the GGUF pinned by the QVAC SDK catalog. Model weights are downloaded separately.

```sh
npm ci
npm test
python3 app/build.py --model /absolute/path/to/refiner.gguf
open .local/app/RambleFlow.app
```

This build uses the QVAC speech recognizer and the refiner you supply. On first launch, it downloads the QVAC Parakeet speech model. Allow microphone access to dictate and Accessibility access to use the global shortcut and insert text into other apps. The development build points to this checkout. It preserves the selected model across rebuilds. To change weights, run `node app/select-model.mjs .local/app/config.json /absolute/path/to/refiner.gguf` and choose Reload models in the app. This resets automatic insertion to preview mode. For a new configuration with an adapter, build into a fresh `--output` directory under `.local/`.

## Privacy

Normal dictation processes audio and text locally. The app keeps usage counts on disk and holds the last result in memory for quick paste. Developer replay tracing, when explicitly enabled, can write raw audio and transcripts to disk.

## Package a standalone build

```sh
python3 app/build.py --bundle --model /absolute/path/to/refiner.gguf --output .local/bundle
```

Use a standalone Node distribution and a fresh output directory for each bundle. Add `--adapter /absolute/path/to/adapter.gguf` when using a compatible adapter. A bundle includes the supplied refiner files and the pinned runtime dependencies. Before distributing one, verify redistribution rights for the included weights and dependencies, then complete macOS signing and notarization.

## Contributing

Run `npm test` before submitting changes. For dictation issues, include the macOS version, model, and steps to reproduce. Use synthetic examples when reporting issues involving audio or transcripts.

## License and credits

RambleFlow source is licensed under [GPL-3.0-only](LICENSE). The optional fast speech path uses the local ASR sidecar from Phonon by Infatoshi. See the [third-party notices](THIRD_PARTY_NOTICES.md) for credits and licenses.
