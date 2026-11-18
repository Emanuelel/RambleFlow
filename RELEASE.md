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

GitHub limits each release file to 2 GiB, and the timed speech model alone is 2.47 GB. So the installer carries no weights. On first launch the app downloads:

| Model | Source | Size |
| --- | --- | --- |
| Timed speech recognition | [MLX Community Parakeet TDT 0.6B v2](https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v2/tree/8ae155301e23d820d82aa60d24817c900e69e487), pinned commit | 2.47 GB |
| Cleanup refiner | `literal192-q4.gguf`, attached to the GitHub release | 1.05 GB |
| Speech fallback | QVAC Parakeet, from the QVAC registry | about 0.86 GB |

Each file's size and SHA-256 are checked before use; the pinned hashes are in `app/model-download.mjs` and the app's `default-refiner.json`. Downloads go to `~/Library/Application Support/RambleFlow/models`, outside the runtime that upgrades replace.

1. Build the app without bundling the refiner:
   `python3 app/build.py --bundle --fast-runtime --model /absolute/path/to/literal192-q4.gguf --refiner-url https://github.com/Emanuelel/RambleFlow/releases/download/vVERSION/literal192-q4.gguf --output .local/release-VERSION --identity "Developer ID Application: ..."`
2. Package and notarize: `NOTARY_PROFILE=rambleflow scripts/package-release.sh VERSION .local/release-VERSION/RambleFlow.app /path/to/timed-runtime .local/release-VERSION`. The runtime folder holds `python` and `Phonon.app`; any `asr-model` folder is left out. The script refuses an image with weights in it or one over 2 GiB, and prints its SHA-256.
3. Create release `vVERSION` with two files: the disk image and `literal192-q4.gguf`. The file name must match the `--refiner-url`.
4. Fill in the version, image URL and SHA-256 in [the cask template](packaging/rambleflow.rb.in) and save it as `Casks/rambleflow.rb` in the `Emanuelel/homebrew-rambleflow` tap.

Install command once the repository, release and tap are public: `brew install --cask emanuelel/rambleflow/rambleflow`.

The cask installs the `timed-runtime` directory into `~/Library/Application Support/RambleFlow/timed-runtime`. On first launch, the app reads the runtime there and enables punctuation reuse. Existing app settings are preserved. An older install that kept its speech model in `timed-runtime/asr-model` uses the downloaded copy once an upgrade replaces that folder.

## Before publishing a cask

1. Complete refiner training-data provenance and prepare the model card, licenses and notices. Supply the corresponding source for the sidecar release payload.
2. Package the runtime with pinned artifact hashes. Sign and notarize the final build, then publish the matching cask checksum.
3. On a clean Apple silicon system, verify Brew install, first launch, runtime and model selection, dictation, and cross-app insertion. Confirm offline dictation after setup and measure the fast path on a physical Mac.
