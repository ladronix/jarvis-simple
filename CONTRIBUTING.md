# Contributing

Thanks for helping. Jarvis Simple is deliberately small: voice to text at the cursor, nothing
else. Bug fixes and polish are welcome; for a new feature, open an issue first so we can agree it
fits.

## Setup

Apple Silicon Mac, macOS 26+, Xcode 26+ and `brew install xcodegen`.

```bash
scripts/make-dev-cert.sh          # once: local signing certificate, keeps permissions across rebuilds
cd Core && swift build && swift test
cd .. && scripts/lint.sh          # scripts/lint.sh --fix formats
scripts/build.sh Debug --open     # build and launch the app
```

[AGENTS.md](AGENTS.md) describes the code layout and the macOS behaviors the code depends on;
read its "Runtime facts" before touching audio capture, insertion or hotkeys.

## Pull requests

- One topic per pull request, conventional commit subjects (`fix:`, `feat:`, `docs:`, …).
- CI must pass: build, tests and `swift format lint --strict`.
- Add a test for logic changes in `Core`. Describe how you checked UI or insertion changes by hand.
- Dependencies: change `Core/Package.swift`, run `swift package update` in `Core`, and commit the
  new `Package.resolved`. Builds refuse versions that are not in that file.
- Models: change the pins in `scripts/model-manifest.py`, run it, and commit the regenerated
  `ModelManifest+Pinned.swift`.
- Never commit recordings of your voice, transcripts, certificates or keys.

By contributing you agree that your work is released under the [MIT License](LICENSE).
