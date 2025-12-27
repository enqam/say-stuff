# 🎙️ Say Stuff — Voice-to-Text for Mac

Hold a button, speak, release — your words appear instantly wherever you're typing.

No internet required. Everything runs locally on your Mac.

---

## ⚡ Quick Install (Recommended)

**Open the Terminal app** (find it in Applications → Utilities → Terminal) and paste these commands:

```bash
# Download Say Stuff
git clone https://github.com/enqam/say-stuff.git ~/say-stuff
cd ~/say-stuff

# Run the installer
chmod +x install.sh
./install.sh
```

The installer will guide you through everything. Just follow the prompts!

---

## 🎮 How to Use

Once installed:

1. **Click anywhere you can type** (a chat app, email, document, etc.)
2. **Hold** `⌥⌘V` (Option + Command + V) on your keyboard
3. **Speak** while holding the keys
4. **Release** — your words appear!

### Hotkeys

| Keys | What it does |
|------|--------------|
| `⌥⌘V` | Record → Auto-detect language |
| `⌥⌘E` | Record → English only |
| `⌥⌘C` | Record → Russian only |

### Visual Feedback

| Icon | Meaning |
|------|---------|
| ⏳ Arming mic | Getting ready... |
| 🎙️ Recording | Speak now! |
| ⏳ Transcribing | Processing your speech... |
| ✅ Dictation pasted | Done! Text has been inserted |

---

## 🔧 Choosing a Model

During installation, you'll choose an AI model. Bigger models = better accuracy but need more RAM.

| Model | Size | RAM Needed | Best For |
|-------|------|------------|----------|
| `large-v3-turbo` | 1.6 GB | 16+ GB | **Best quality** — recommended for modern Macs |
| `medium` | 1.5 GB | 8+ GB | Great balance of quality and speed |
| `small` | 466 MB | 4+ GB | Fast, good accuracy |
| `base` | 142 MB | 2+ GB | Very fast, basic accuracy |

### How to switch models later

1. Download a new model:
   ```bash
   cd ~/whisper.cpp/models
   ./download-ggml-model.sh medium
   ```

2. Edit the config file:
   ```bash
   open -e ~/.hammerspoon/init.lua
   ```

3. Find this line and change the model name:
   ```lua
   local model = os.getenv("HOME") .. "/whisper.cpp/models/ggml-large-v3-turbo.bin"
   ```
   Change `large-v3-turbo` to your new model (e.g., `medium`).

4. Reload Hammerspoon (click its menu bar icon → Reload Config)

---

## 🛠️ Troubleshooting

### "No audio captured" error
- **Check your microphone is working** in System Settings → Sound → Input
- **Grant microphone access**: System Settings → Privacy & Security → Microphone → Enable Hammerspoon

### Nothing happens when I press the keys
- **Open Hammerspoon** from Applications
- **Grant accessibility access**: System Settings → Privacy & Security → Accessibility → Enable Hammerspoon
- **Reload config**: Click Hammerspoon menu bar icon → Reload Config

### Text goes into wrong window
- Make sure the window where you want text is **focused** (click on it) before releasing the keys

### Transcription is slow
- Try a smaller model (see "Choosing a Model" above)
- Close other heavy apps to free up RAM

---

## 📋 What Gets Installed

The installer sets up:

- **Homebrew** — Mac's package manager (if not already installed)
- **ffmpeg** — Records audio from your microphone  
- **Hammerspoon** — Listens for your hotkey presses
- **whisper.cpp** — The AI that converts speech to text (runs on your Mac's GPU)

Everything runs **100% locally** — your voice never leaves your computer.

---

## 🗑️ Uninstall

To remove everything:

```bash
# Remove the script
rm -rf ~/.hammerspoon

# Remove whisper.cpp
rm -rf ~/whisper.cpp

# Remove Hammerspoon (optional)
brew uninstall --cask hammerspoon

# Remove ffmpeg (optional)
brew uninstall ffmpeg
```

---

## 📄 License

MIT — free to use, modify, and share.
