# Security

## Reporting a vulnerability

Please report security problems privately through
[GitHub private vulnerability reporting](https://github.com/ladronix/jarvis-simple/security/advisories/new),
not in a public issue. Include the version (menu → About, or `CFBundleShortVersionString`), your
macOS version and steps to reproduce. You will get an answer within a few days. Fixes ship as a
new release and an advisory on this repository.

Only the latest release is supported.

## What Jarvis Simple does

- **Microphone:** only between start and stop of a recording. Audio stays in memory and is
  discarded after each recording.
- **Accessibility:** used to find the focused text field and insert the text, or to send ⌘V.
  Jarvis reads the field's value only to check that the insertion arrived.
- **Clipboard:** the paste path puts the text on the clipboard (marked transient, so clipboard
  managers skip it), sends ⌘V and restores the previous contents.
- **Network:** only to download the speech models. Nothing else is sent anywhere: no analytics,
  no accounts, no update checks.
- **Storage:** settings in `~/Library/Preferences/com.ladronix.jarvis.plist`, models in
  `~/Library/Application Support/Jarvis/Models`. Transcripts are never written to disk or logs.

## Supply chain

- **Releases** are signed with a Developer ID certificate, notarized by Apple and stapled. Each
  release lists the SHA-256 of its disk image; the Homebrew cask pins the same hash.
- **Models** are downloaded from fixed Hugging Face commits over HTTPS. Every file is checked
  against the size and SHA-256 recorded in
  [`ModelManifest+Pinned.swift`](Core/Sources/JarvisCore/Models/ModelManifest+Pinned.swift)
  before it is used; a file that does not match is deleted and downloaded again. A weekly job
  confirms the pinned files are still published unchanged.
- **Dependencies** are resolved once into the committed `Core/Package.resolved`; every build
  (local, CI and release) refuses other versions. Dependabot proposes updates as pull requests.
- **Code changes** reach `main` only through pull requests that pass CI.

## Out of scope

Jarvis runs with your user's rights. Software that already runs as the same user can change the
app's settings or model files; protecting against that is up to macOS, not Jarvis.
