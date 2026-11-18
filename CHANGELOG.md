# Changelog

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
