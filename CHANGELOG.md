# Changelog

The release installer no longer carries model weights, so it fits GitHub's 2 GiB limit for a release file. On first launch the app downloads the timed speech model from its pinned Hugging Face commit and the Literal192 cleanup model from the GitHub release, checks each file's size and SHA-256, and shows both on the setup progress card. Downloaded models live in the models folder, so an upgrade that replaces the runtime keeps them. `scripts/package-release.sh` builds the image and refuses one that contains weights or exceeds 2 GiB.

Disable sidecar Python bytecode writes so vocabulary imports preserve the signed helper bundle.

Recover the identical bundled cleanup model when a saved model path disappears during a runtime upgrade.

RambleFlow now shows its app icon in the Dock. Clicking it brings the main window back.

Improved saved vocabulary recognition in the fast Parakeet runtime by adjusting how it completes dictionary terms.

## Unreleased

- Prepared the native macOS app and its tests for source distribution.
- Added explicit refiner selection for both development and standalone builds.
- Documented the fast release runtime and included third-party notices in app builds.
- Added first-launch configuration for the Brew-installed timed ASR runtime and the exact bundled Literal192 Q4 refiner.
- Ported the current Fn shortcut, onboarding, automatic insertion, sidebar, menu bar and vocabulary editor from the private app branch.
- Apply saved vocabulary to timed Parakeet recognition and direct the cleanup model to preserve saved spellings.
