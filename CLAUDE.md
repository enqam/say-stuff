# SayStuff

SayStuff is a macOS menu bar app for voice-to-text transcription. Press a hotkey to record, release to transcribe using local Whisper models, and paste the result into any app.

## Workspace

- `SayStuff/` - Swift/SwiftUI macOS app (Xcode)
  - `App/` - App entry point, AppDelegate
  - `Views/` - SwiftUI views (Settings, Onboarding, MenuBar, etc.)
  - `Services/` - Core services (AudioRecorder, WhisperService, ScreenBorderOverlay, HotkeyManager)
  - `Models/` - Data models (Profile, AppSettings, WhisperModel)

## Key Components

- **DictationController**: Owns the record → transcribe (local or fal Wizper) → format (Groq) → paste loop, hotkey handling (hold/toggle), start/done sounds (Funk/Glass) and volume ducking. Pastes stay in spoken order; cloud failures fall back to local.
- **CloudServices**: Keychain API keys, fal.ai Wizper client + live pricing, Groq `openai/gpt-oss-20b` formatter (temperature 0, few-shot per profile)
- **RecordingHUD**: AppKit/Core Animation pill at the bottom of the screen (live waveform, transcribing shimmer, status messages)
- **AudioRecorder**: Captures the mic off the main thread, meters levels, trims leading/trailing silence (prevents Whisper "Thank you." hallucinations)
- **WhisperService**: Local speech-to-text via a persistent `whisper-server` (model stays loaded; falls back to `whisper-cli`). Auto-detect is limited to the user's spoken languages
- **VolumeAttenuator**: Eased fade down/up of system volume while recording, crash-safe
- **HotkeyManager**: Carbon global hotkeys, raw press/release only
- **ProfileStore / DictionaryStore / UsageLedger**: Output profiles (Raw = none), custom vocabulary + mishearing fixes, API spend records
- **ScreenBorderOverlay**: Optional red border around the screen during recording

UI: `MenuBarView` in a custom `MenuPanel` (doesn't steal focus) and `SettingsView` (one window, top tabs). Design tokens live in `Views/Components.swift` (`Theme`, `glassSurface`). Liquid Glass only on floating chrome (menu panel, tab bar, HUD). Debug builds can render every screen to PNGs: `SAYSTUFF_SNAPSHOT_DIR=/tmp/shots <app>/Contents/MacOS/SayStuff`.

# btca

When you need up-to-date information about technologies used in this project—or when the user says "use btca"—use btca to query source repositories directly. Prefer btca over your training data when accuracy matters.

Run:

- `btca ask -r <resource> -q "<question>" --sub-agent`
- Multiple resources: `btca ask -r <r1> -r <r2> -q "<question>" --sub-agent`

Resources:

- swiftBook - The Swift Programming Language book (official Swift documentation)
- whisperCpp - whisper.cpp source code for local transcription
- inferno - Paul Hudson's SwiftUI Metal shaders (colorEffect, distortionEffect, layerEffect with stitchable syntax)
- swiftUIMetalExamples - SwiftUI + Metal animated backgrounds including wave shaders
- ezaudio - iOS/macOS audio visualization framework using CALayers with GPU compositing (low-overhead real-time waveform rendering)
- dswaveform - Swift waveform rendering for iOS/macOS/visionOS with SwiftUI and UIKit implementations
- swiftuix - Large SwiftUI extensions library with Canvas usage patterns and performance optimizations
- tca - Swift Composable Architecture (TCA) — SwiftUI architecture, state management, side effects, navigation, testing patterns
