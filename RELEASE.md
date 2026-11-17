# macOS release

The Homebrew target is the Apple silicon build with timed speech recognition and transcript cleanup during dictation. The source build in the README uses the QVAC speech recognizer and a user-supplied refiner.

## Runtime

| Component | Release target |
| --- | --- |
| Timed speech recognition | Phonon v1.0.1 ASR sidecar with NVIDIA Parakeet TDT 0.6B v2, MLX conversion pinned in the notices |
| Sidecar environment | Relocatable arm64 CPython and locked runtime packages |
| Cleanup | QVAC with the merged, quantized Broad1291 + Literal192 Qwen3-1.7B refiner |
| Preview reuse | Enabled, including punctuation-only updates |
| Speech fallback | QVAC Parakeet |

Build the cask app with `app/build.py --bundle --fast-runtime --model /absolute/path/to/literal192-q4.gguf --output .local/fast-release`. The signed app bundles the exact merged refiner. The cask installs the `timed-runtime` directory into `~/Library/Application Support/RambleFlow/timed-runtime`. On first launch, the app reads the runtime there and enables punctuation reuse. Existing app settings are preserved. The app source and [third-party notices](THIRD_PARTY_NOTICES.md) are tracked here. Model weights are separate artifacts.

Archive `RambleFlow.app` and `timed-runtime` at the archive root. The runtime directory contains `python`, `Phonon.app` and `asr-model`; the cleanup weights are already inside RambleFlow.app. Fill in the version, archive URL and archive SHA-256 in [the cask template](packaging/rambleflow.rb.in) and save it as `Casks/rambleflow.rb` in the tap.

## Before publishing a cask

1. Complete refiner training-data provenance and prepare the model card, licenses and notices. Supply the corresponding source for the sidecar release payload.
2. Package the runtime with pinned artifact hashes. Sign and notarize the final build, then publish the matching cask checksum.
3. On a clean Apple silicon system, verify Brew install, first launch, runtime and model selection, dictation, and cross-app insertion. Confirm offline dictation after setup and measure the fast path on a physical Mac.
