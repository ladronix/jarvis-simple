# Jarvis Simple — privacy

What the application processes and where. Version 0.1.0.

## 1. Purpose

Jarvis Simple is a macOS menu-bar application that converts the user's own speech into text and
inserts it at the cursor of the application they are working in. It is a personal productivity
tool; it does not provide the text to anyone else.

## 2. Processing overview

| Step | Data | Where | Retention |
|---|---|---|---|
| Recording | Microphone audio (16 kHz mono) | RAM of the user's Mac | Discarded at the end of each recording (seconds) |
| Speech recognition | Audio chunks, recognized text | Apple Neural Engine on the Mac (WhisperKit, Silero VAD) | Not stored |
| Delivery | Recognized text | Focused application via Accessibility, or a ⌘V paste (pasteboard marked transient, previous contents restored after ≤ 1 s). In copy-only mode, or when insertion is not possible, the text is left on the pasteboard for the user to paste | Under the user's control in the target app |
| Diagnostics | Timings, chunk counts, audio level peak, device names, app bundle ids | Apple unified log on the Mac | System default (in-memory / hours); no transcript text is ever logged |

No processing happens outside the user's Mac.

## 3. Data

- Voice: never stored or transmitted; processed transiently for recognition only.
- Content of dictation: whatever the user says. Delivered only to the destination the user chose.
- Configuration: preferred languages, keyboard shortcuts, microphone name, vocabulary words the
  user entered, feature toggles. Stored in the app's preferences (`com.ladronix.jarvis`) on the
  Mac.
- No identifiers: no user id, account, e-mail, device id or usage statistics are collected.

## 4. Network

- **Model download (one time):** the application downloads the speech model and the voice
  activity model from `huggingface.co` on first use (about 1.6 GB). The request carries no user
  data beyond what any HTTPS download exposes (IP address, user agent).
- **Feedback (user-initiated):** "Report an Issue…" opens the browser at the GitHub issue tracker
  with a pre-filled template containing the app version, macOS version and model name. The user
  decides what else to write and whether to submit.
- Nothing else. No analytics, crash reporting, update checks or cloud services.

## 5. Storage on the device

| Item | Location | Removal |
|---|---|---|
| Settings | User defaults `com.ladronix.jarvis` | Settings → Privacy → Reset Settings, or delete the app's preferences |
| Models | `~/Library/Application Support/Jarvis/Models` (speech) and `~/Library/Application Support/FluidAudio` (voice activity) | Settings → Privacy → Delete Models…, or delete the folders |
| Application | `/Applications/Jarvis.app` | Move to Trash |

Audio and text are never written to disk by the application.

## 6. macOS permissions and why

| Permission | Use | Not used for |
|---|---|---|
| Microphone | Capturing speech while the user records | Background listening (capture runs only between start and stop) |
| Accessibility | Placing text at the cursor, reading the focused text field once to verify the insertion, sending ⌘V to the focused app | Reading other screen content, monitoring keystrokes |

Input Monitoring, Screen Recording, Contacts, Calendar, Location, Camera and Full Disk Access are
not requested. The application refuses to insert text while macOS secure input is active
(password fields).

## 7. Security

- Runs as the user, no privileged helper, no network listener.
- Hardened Runtime enabled. Released builds are signed with a Developer ID and notarized by Apple;
  builds from source are signed with a local certificate created on the Mac that builds them.
- Dependencies: WhisperKit (Argmax, MIT), FluidAudio (Apache-2.0), swift-argument-parser (Apple).
  Reviewed for network use: only the model download endpoints above.
- Personal audio fixtures are git-ignored; the repository holds one synthetic test sample.

## 8. Your control

All data is on your own device and under your control; there is no server, no central storage
and no way for the developer to access your recordings or text. Deleting the application, its
preferences and the models folder removes everything.
