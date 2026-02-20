# SayStuff

SayStuff is a macOS menu bar app for voice-to-text transcription. Press a hotkey to record, release to transcribe using local Whisper models, and paste the result into any app.

## Workspace

- `SayStuff/` - Swift/SwiftUI macOS app (Xcode)
  - `App/` - App entry point, AppDelegate
  - `Views/` - SwiftUI views (Settings, Onboarding, MenuBar, etc.)
  - `Services/` - Core services (AudioRecorder, WhisperService, ScreenBorderOverlay, HotkeyManager)
  - `Models/` - Data models (Profile, AppSettings, WhisperModel)

## Key Components

- **ScreenBorderOverlay**: Lightweight border around the screen during recording
- **AudioRecorder**: Captures microphone input
- **WhisperService**: Local speech-to-text using whisper.cpp
- **HotkeyManager**: Global hotkey registration

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
