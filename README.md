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

## Share With a Friend (Fastest)

1. On your Mac, run `./scripts/release.sh <version>` (example: `./scripts/release.sh 0.5.1`).
2. Send your friend `releases/SayStuff-<version>.dmg`.
3. They open the DMG, drag SayStuff into `/Applications`, and launch it.

Notes:
- The release script will try to bundle `whisper-cli` into the app automatically (so your friend doesn't need to install whisper.cpp). If it can't find `whisper-cli`, it will print a warning and your friend will need to install it or you can re-run with `WHISPER_CLI_PATH=/path/to/whisper-cli`.
- On first run, SayStuff can download the Whisper model in-app and will prompt for permissions.

## Install (Build from Source)

1. Open `SayStuff.xcodeproj` in Xcode.
2. Build and run the app.

## Setup

1. Launch SayStuff. On first run, the onboarding will guide you through downloading a model and granting permissions.
2. If needed, open Settings → Model and confirm the `whisper-cli` path and model directory.
3. Grant permissions when prompted:
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
