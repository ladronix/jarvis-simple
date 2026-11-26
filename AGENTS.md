# Jarvis Simple — agent guide

Native macOS menu-bar dictation app (Swift 6, SwiftUI, WhisperKit). Speak, text lands at the
cursor of whatever app has focus, terminals included. Fully on-device, free, no account. Voice
transcription only, nothing else. Public project of the `ladronix` GitHub account; keep changes
small and keep the app runnable.

## Layout

| Path | Role |
|---|---|
| `App/JarvisApp.swift` | `@main`, `MenuBarExtra` + `Settings` scenes, `AppDelegate` (accessory activation policy). |
| `App/AppModel.swift` | MainActor state machine idle → recording → processing, generation counter for cancel, hotkey wiring incl. push-to-talk, delivery (insert / copy), permissions, onboarding, notifications. |
| `App/MenuBarView.swift`, `SettingsView.swift`, `OnboardingWindow.swift` | UI. Settings has a `HotkeyRecorder` (local NSEvent monitor). |
| `Core/Sources/JarvisCore/Audio/` | `AudioCapture` (AVCaptureSession → 16 kHz mono Float32 stream, silent-input and no-input watchdogs), `AudioDevices` (CoreAudio enumeration, transport type, name-based fallback), `AudioFile` (fixtures). |
| `Core/Sources/JarvisCore/VAD/VADChunker.swift` | Silero VAD (FluidAudio, 4096-sample blocks) driving the Python-era chunking rules: 250 ms min speech, 600 ms silence closes a chunk, 14 s max, flush on stop. |
| `Core/Sources/JarvisCore/Transcription/` | `Transcriber` protocol, `WhisperKitTranscriber` (actor, one `WhisperKit` instance), `WhisperModels` catalog, `ModelManager` (download progress, prewarm, switch). |
| `Core/Sources/JarvisCore/Text/` | `HallucinationFilter` (regex list + structural checks), `TranscriptAssembler` (ordered by chunk index, drops duplicates). |
| `Core/Sources/JarvisCore/Session/DictationSession.swift` | One recording: capture → VAD → sequential transcription queue → assembler; `stop()` flushes and drains, `cancel()` discards. |
| `Core/Sources/JarvisCore/Injection/` | `FocusSnapshot`, `TextInjector` ladder, `AXInserter` / `PasteInserter` / `TypingInserter`, `InsertionPolicy` per bundle id, `SecureInput`. |
| `Core/Sources/JarvisCore/Hotkeys/` | Carbon `RegisterEventHotKey` manager, `Hotkey` (key code + modifiers, layout-aware display). |
| `Core/Sources/JarvisCore/Settings/SettingsStore.swift` | `@Observable` settings in UserDefaults; one-time migration from `~/.jarvis_config.json`. |
| `Core/Sources/jarvis-cli/main.swift` | `transcribe`, `detect`, `bench`, `models`, `record`, `inject`, `doctor`. |
| `Core/Tests/` | Swift Testing suites; `Fixtures/` holds one synthetic Czech sample (personal recordings are git-ignored). |
| `project.yml`, `scripts/` | xcodegen spec; `build.sh` (Debug build + launch), `package.sh` (Release → `dist/*.dmg`, `*.pkg`, `--install`), `make-dev-cert.sh` (local signing certificate), `render-icons.sh` (SVG → asset catalog), `lint.sh` (swift-format). |
| `App/Design/` | SVG source of the app icon (original artwork; `scripts/render-icons.sh` rasterizes it). Menu and settings use SF Symbols. |

Models: `~/Library/Application Support/Jarvis/Models`. Settings: UserDefaults `com.ladronix.jarvis`.
Logs: unified log, subsystem `com.ladronix.jarvis` (`/usr/bin/log stream …`; `log` alone is a zsh builtin).

## Runtime facts you must respect

- **WhisperKit variant names are explicit** in `WhisperModel.catalog`; verify a new one exists in
  `argmaxinc/whisperkit-coreml` before adding it. `detectLangauge` (sic) is the real method name and
  returns log-probabilities for the top language only.
- **Audio capture is `AVCaptureSession` on purpose.** Selecting a specific input on
  `AVAudioEngine`'s input node was unreliable on macOS 27 (stale formats after a device switch,
  error -10868, silent taps). Do not switch back without re-testing built-in, Bluetooth and
  system-default devices with `jarvis-cli record --device`.
- **Focus lookup:** `AXUIElementCreateSystemWide` + focused element fails on macOS 27 (-25204);
  ask `AXUIElementCreateApplication(frontmost pid)` first. AX writes must be verified (Safari
  answers success and inserts nothing). Synthetic unmodified keystrokes are dropped from an
  ad-hoc-signed app; ⌘V is not. Typing is therefore not in the default ladder.
- **Clipboard restore delay:** 900 ms for paste-first apps (Electron, terminals), 500 ms otherwise.
  Shorter and VS Code pastes the *old* clipboard.
- **Segment filter** follows Whisper's rule (drop only if noSpeech > 0.6 **and** avgLogprob < −1).
  Filtering on noSpeech alone throws away quiet real speech.
- Bluetooth headset microphones (HFP, 24 kHz) sometimes deliver nothing; the 3 s watchdog reports
  it. `preferBuiltInMic` setting exists (default off).
- **Signing:** Xcode builds ad-hoc (no team); `scripts/build.sh` and `scripts/package.sh` then
  deep re-sign with the local self-signed "Jarvis Dev" certificate (`scripts/make-dev-cert.sh`).
  TCC binds grants to that certificate, so Accessibility survives rebuilds. Without the cert,
  every rebuild silently loses the grant while System Settings still shows it as on. CoreML/ANE
  specialization is cached per model; a changed binary may or may not re-run it (1–2 min).
- `package.sh --install` installs to `/Applications` (with sudo when available) and falls back to
  `~/Applications` without admin rights.
- Minimum macOS 26, Swift 6 language mode, strict concurrency. The app target compiles with
  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`; the core package uses explicit actors.
- Repository: `github.com/ladronix/jarvis-simple` (SSH host alias `github.com-ladronix`, commit
  identity `ladronix@users.noreply.github.com`). Work on a feature branch and merge via PR.
- The bundle id changed from an earlier build: a Mac that ran the old app needs Microphone and
  Accessibility granted again for `com.ladronix.jarvis`; old preferences are not carried over.

## Verify before you claim it works

```bash
cd Core && swift build && swift test
cd .. && scripts/lint.sh                   # swift-format --strict; scripts/lint.sh --fix to format
scripts/build.sh Debug                     # xcodegen + xcodebuild, prints the .app path
```

For behavior changes in capture, VAD or transcription, also run from the microphone:
`Core/.build/debug/jarvis-cli record --seconds 8` and check the session log line
(`audio N s, peak P, chunks C`). For insertion changes, `jarvis-cli inject "text" --countdown 3`
into TextEdit (AX path) and Safari or a terminal (paste path); the user checks VS Code and Slack
manually, never automate typing into them.

## Conventions

- Conventional commits (`feat:`, `fix:`, `chore:`, `docs:`, `refactor:`), imperative subject.
- Concurrency: `DictationSession`, `VADChunker`, `WhisperKitTranscriber` are actors; anything
  touching AX, CGEvent, NSPasteboard or Carbon is `@MainActor`. Never touch actors from the
  capture callback queue; yield into the `AsyncStream` continuation instead.
- Logging: `Log.<category>` from `Support/Log.swift`. Transcript text stays `.private`; counts,
  timings and device names may be `.public`.
- Hallucination patterns: add to `HallucinationFilter.patterns` with a test; do not loosen the
  structural checks.
- UI strings are English. The product name in UI is "Jarvis Simple"; bundle id `com.ladronix.jarvis`,
  process name `Jarvis`.
- Feedback goes to GitHub issues (`AppModel.issuesURL`); keep that link working.

## Known gaps (as of 2026-11-26)

1. Packages are signed with the local self-signed certificate only: other Macs need right-click →
   Open on first launch. Public distribution needs an Apple Developer ID and notarization.
2. Typing fallback disabled; re-test from a signed app (may work when not ad-hoc).
3. Language allow-list uses "top-1 must be allowed, else auto"; true constrained decoding would
   need per-language token probabilities.
4. App icon is a flat SVG render (no Icon Composer layers); no Czech localization yet.
5. `FocusSnapshot` is taken at insert time only; a snapshot at recording start would let the app
   warn when focus moved.
6. Device hot-plug during a recording is not handled.

## Ways forward (options, not commitments)

Researched 2026-11 against the current dictation market (Wispr Flow, Superwhisper, VoiceInk,
Handy, Claude Code `/voice`). The stack here (Whisper on CoreML/ANE, Silero VAD, AX or paste
insertion) is the same one most of them use; what is missing is listed below, in order of value.

1. **Parakeet TDT 0.6B v3 engine.** NVIDIA's multilingual model (25 European languages incl.
   Czech, built-in language detection), much faster than Whisper. A CoreML build runs on the ANE
   through FluidAudio, which is already a dependency (`FluidInference/parakeet-tdt-0.6b-v3-coreml`).
   Add it behind the `Transcriber` protocol as a second engine, keep Whisper as default, and
   compare on Czech/English and code-mixed recordings (`jarvis-cli bench`). Risk: short mixed
   phrases may be detected as the wrong language.
2. **Optional local LLM cleanup** (punctuation, filler words, self-corrections) via Ollama or MLX
   with a small model. Per-app policy: off for terminals. Keep the raw text recoverable. Apple
   Foundation Models are not an option for Czech.
3. **Replacement dictionary** (spoken form → written form) on top of the vocabulary prompt, for
   names and technical terms the model keeps misspelling.
4. Anything beyond transcription (understanding, answering, acting on commands) belongs in a
   separate project; keep Jarvis Simple a plain, fast dictation tool.
