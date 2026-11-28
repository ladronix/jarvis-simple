# Changelog

All notable changes to Jarvis Simple. Versions follow [Semantic Versioning](https://semver.org).

## [0.1.1] - 2026-11-28

### Security
- Speech and voice-activity models are downloaded from fixed Hugging Face commits and every file
  is checked against its recorded SHA-256 before use. Files that do not match are downloaded
  again. Existing downloads are verified once on the first launch (a few seconds), not fetched
  again.
- Builds use exactly the dependency versions in `Core/Package.resolved`.

### Changed
- Smaller app: unused parts of FluidAudio (a prebuilt text-normalization library, text-to-speech
  and speaker diarization) are no longer included. The app binary went from 25.7 MB to 10.4 MB.
- The voice-activity model now lives with the speech models in
  `~/Library/Application Support/Jarvis/Models`.

### Removed
- One-time import of settings from an earlier prototype (`~/.jarvis_config.json`).

## [0.1.0] - 2026-11-27

First public release: on-device dictation into any app, mixed-language detection, push-to-talk,
Developer ID signed and notarized, Homebrew cask.

[0.1.1]: https://github.com/ladronix/jarvis-simple/releases/tag/v0.1.1
[0.1.0]: https://github.com/ladronix/jarvis-simple/releases/tag/v0.1.0
