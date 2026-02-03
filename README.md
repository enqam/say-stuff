# SayStuff

SayStuff is a macOS menu bar app for local voice-to-text. Hold a hotkey to record, release to transcribe, and the text is pasted into the active app.

## Requirements

- macOS 13+
- `whisper-cli` from whisper.cpp (or another compatible build)
- At least one Whisper model file (.bin)

## Install (Recommended for Non‑Technical Users)

1. Download the latest `SayStuff-<version>.dmg` from GitHub Releases.
2. Open the DMG and drag SayStuff into `/Applications`.
3. On first launch, if macOS warns about an unidentified developer:
   - Right‑click SayStuff in `/Applications` → `Open` → `Open`.

## Install (Build from Source)

1. Open `SayStuff.xcodeproj` in Xcode.
2. Build and run the app.

## Setup

1. Open the SayStuff menu bar icon, then open Settings.
2. In the Model tab, set the `whisper-cli` path and model directory.
3. Download a model in-app, or place a `.bin` model file in the model directory.
4. Grant permissions when prompted:
   - Microphone access (for recording)
   - Accessibility access (for global hotkey and paste)

## Usage

- Hold the hotkey (default: Option+Command+V) to record.
- A red screen border shows while recording.
- Release to transcribe and paste.

## Troubleshooting

- No audio captured: check System Settings > Sound > Input and microphone permissions.
- Hotkey not working: grant Accessibility access for SayStuff.
- `whisper-cli` not found: set the correct path in Settings.

## License

MIT
