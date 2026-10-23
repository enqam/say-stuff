# SayStuff

macOS menu bar dictation (Swift/SwiftUI). Hotkey → record → transcribe → paste.

- Flow lives in `Services/DictationController.swift`. Engines: `ParakeetService` (FluidAudio), `WhisperService` (whisper.cpp), `CloudServices` (Groq, fal.ai; keys in Keychain).
- Design tokens: `Views/Components.swift` (`Theme`).
- Build and install the dev app: `scripts/dev-run.sh`.
- Render every screen to PNGs (Debug): `SAYSTUFF_SNAPSHOT_DIR=/tmp/shots <app>/Contents/MacOS/SayStuff`.
