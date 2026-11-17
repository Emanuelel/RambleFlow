# RambleFlow

RambleFlow is a native macOS dictation app. RambleFlow runs speech recognition and transcript cleanup locally, with QVAC handling cleanup. Hold Fn to dictate, then release to finish. Use the Scratchpad to try it inside RambleFlow.

## Install

The Homebrew cask is pending. The [release checklist](RELEASE.md) describes the runtime the cask will install and the checks required before it can ship.

## Build from source

You need an Apple silicon Mac running macOS 14 or later, Apple's command-line developer tools, Python 3, npm, and a Node version supported by [package.json](package.json). You also need compatible GGUF refiner weights. The app uses a chat-style cleanup prompt and supports an optional LoRA adapter trained against the same base weights.

For a starter model, use [Qwen3-1.7B-Q4_0.gguf](https://huggingface.co/unsloth/Qwen3-1.7B-GGUF/blob/d7f544eead698dbd1f15126ef60b45a1e1933222/Qwen3-1.7B-Q4_0.gguf), the GGUF pinned by the QVAC SDK catalog. Model weights are downloaded separately.

```sh
npm ci
npm test
python3 app/build.py --model /absolute/path/to/refiner.gguf
open .local/app/RambleFlow.app
```

This build uses the QVAC speech recognizer and the refiner you supply. On first launch, it downloads the QVAC Parakeet speech model. Allow microphone access to dictate and Accessibility access to use the global shortcut and insert text into other apps. The development build points to this checkout. It preserves the selected model across rebuilds. To change weights, run `node app/select-model.mjs .local/app/config.json /absolute/path/to/refiner.gguf` and choose Reload models in the app. This resets automatic insertion to preview mode. For a new configuration with an adapter, build into a fresh `--output` directory under `.local/`.

Normal dictation processes audio and text locally. The app keeps usage counts on disk and holds the last result in memory for quick paste. Developer replay tracing, when explicitly enabled, can write raw audio and transcripts to disk.

## Package a standalone build

```sh
python3 app/build.py --bundle --model /absolute/path/to/refiner.gguf --output .local/bundle
```

Use a standalone Node distribution and a fresh output directory for each bundle. Add `--adapter /absolute/path/to/adapter.gguf` when using a compatible adapter. A bundle includes the supplied refiner files and the pinned runtime dependencies. Before distributing one, verify redistribution rights for the included weights and dependencies, then complete macOS signing and notarization.

## Contributing

Run `npm test` before submitting changes. For dictation issues, include the macOS version, model, and steps to reproduce. Use synthetic examples when reporting issues involving audio or transcripts.

RambleFlow source is licensed under [GPL-3.0-only](LICENSE). The optional fast speech path uses the local ASR sidecar from Phonon by Infatoshi. See the [third-party notices](THIRD_PARTY_NOTICES.md) for credits and licenses.
