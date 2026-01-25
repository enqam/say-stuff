#!/bin/bash

# ============================================================================
# Say Stuff - One-Click Installer for macOS
# ============================================================================
# This script installs everything needed for push-to-talk voice transcription.
# It will guide you through each step and ask for permission when needed.
# ============================================================================

set -e  # Exit on any error

# Capture script directory BEFORE any cd commands
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for pretty output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Print helpers
info() { echo -e "${BLUE}ℹ${NC} $1"; }
success() { echo -e "${GREEN}✅${NC} $1"; }
warn() { echo -e "${YELLOW}⚠️${NC} $1"; }
error() { echo -e "${RED}❌${NC} $1"; exit 1; }
step() { echo -e "\n${BOLD}${BLUE}==> Step $1: $2${NC}"; }

# Check if running on macOS
if [[ "$(uname)" != "Darwin" ]]; then
    error "This script only works on macOS. For Windows, use AutoHotkey (see README)."
fi

echo -e "${BOLD}"
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║              🎙️ Say Stuff - Voice Transcription               ║"
echo "║                     One-Click Installer                       ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo "This will install everything you need for push-to-talk transcription."
echo "The installer will ask for your password when needed."
echo ""
read -p "Press Enter to continue (or Ctrl+C to cancel)..."

# ============================================================================
step "1/8" "Checking for Homebrew (macOS package manager)"
# ============================================================================

if command -v brew &> /dev/null; then
    success "Homebrew is already installed"
else
    info "Homebrew not found. Installing..."
    echo ""
    echo "You may be asked for your Mac password. This is normal."
    echo ""
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    
    # Add Homebrew to PATH for this session (Apple Silicon)
    if [[ -f "/opt/homebrew/bin/brew" ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
    success "Homebrew installed"
fi

# ============================================================================
step "2/8" "Installing ffmpeg (audio recording)"
# ============================================================================

if command -v ffmpeg &> /dev/null; then
    success "ffmpeg is already installed"
else
    info "Installing ffmpeg..."
    brew install ffmpeg
    success "ffmpeg installed"
fi

# ============================================================================
step "3/8" "Installing Hammerspoon (hotkey automation)"
# ============================================================================

if [[ -d "/Applications/Hammerspoon.app" ]] || [[ -d "$HOME/Applications/Hammerspoon.app" ]]; then
    success "Hammerspoon is already installed"
else
    info "Installing Hammerspoon..."
    brew install --cask hammerspoon
    success "Hammerspoon installed"
fi

# ============================================================================
step "4/8" "Installing cmake (build tool)"
# ============================================================================

if command -v cmake &> /dev/null; then
    success "cmake is already installed"
else
    info "Installing cmake..."
    brew install cmake
    success "cmake installed"
fi

# ============================================================================
step "5/8" "Building whisper.cpp (AI transcription engine)"
# ============================================================================

WHISPER_DIR="$HOME/whisper.cpp"

if [[ -f "$WHISPER_DIR/build/bin/whisper-cli" ]]; then
    success "whisper.cpp is already built"
else
    info "Cloning whisper.cpp..."
    if [[ -d "$WHISPER_DIR" ]]; then
        warn "whisper.cpp folder exists but not built. Rebuilding..."
    else
        git clone https://github.com/ggerganov/whisper.cpp.git "$WHISPER_DIR"
    fi
    
    cd "$WHISPER_DIR"
    info "Building with Metal (GPU) support for Apple Silicon..."
    cmake -B build -DWHISPER_METAL=ON
    cmake --build build --config Release -j$(sysctl -n hw.ncpu)
    success "whisper.cpp built successfully"
fi

# ============================================================================
step "6/8" "Downloading AI model"
# ============================================================================

echo ""
echo "Choose a model based on your Mac's RAM:"
echo ""
echo "  ${BOLD}1) large-v3-turbo${NC} (1.6 GB) - Best quality + speed [Recommended]"
echo "     └─ Needs: 16+ GB RAM"
echo ""
echo "  ${BOLD}2) medium${NC} (1.5 GB) - Great quality, good for most Macs"
echo "     └─ Needs: 8+ GB RAM"
echo ""
echo "  ${BOLD}3) small${NC} (466 MB) - Good quality, fastest"
echo "     └─ Needs: 4+ GB RAM"
echo ""
echo "  ${BOLD}4) base${NC} (142 MB) - Basic quality, very fast"
echo "     └─ Needs: 2+ GB RAM"
echo ""

# Get system RAM
RAM_GB=$(( $(sysctl -n hw.memsize) / 1073741824 ))
info "Your Mac has ${BOLD}${RAM_GB} GB${NC} of RAM"

# Default recommendation
if [[ $RAM_GB -ge 16 ]]; then
    DEFAULT_MODEL="1"
elif [[ $RAM_GB -ge 8 ]]; then
    DEFAULT_MODEL="2"
elif [[ $RAM_GB -ge 4 ]]; then
    DEFAULT_MODEL="3"
else
    DEFAULT_MODEL="4"
fi

echo ""
read -p "Enter your choice [1-4, default: $DEFAULT_MODEL]: " MODEL_CHOICE
MODEL_CHOICE=${MODEL_CHOICE:-$DEFAULT_MODEL}

case $MODEL_CHOICE in
    1) MODEL_NAME="large-v3-turbo" ;;
    2) MODEL_NAME="medium" ;;
    3) MODEL_NAME="small" ;;
    4) MODEL_NAME="base" ;;
    *) MODEL_NAME="large-v3-turbo" ;;
esac

MODEL_FILE="$WHISPER_DIR/models/ggml-$MODEL_NAME.bin"

if [[ -f "$MODEL_FILE" ]]; then
    success "Model '$MODEL_NAME' already downloaded"
else
    info "Downloading '$MODEL_NAME' model (this may take a few minutes)..."
    cd "$WHISPER_DIR/models"
    bash download-ggml-model.sh "$MODEL_NAME"
    success "Model downloaded"
fi

# ============================================================================
step "7/8" "Detecting your microphone"
# ============================================================================

echo ""
info "Available microphones on your Mac:"
echo ""

# Get list of audio input devices - extract just the device names
DEVICES_RAW=$(ffmpeg -f avfoundation -list_devices true -i "" 2>&1 | grep -A 50 "audio devices" | grep "^\[" | head -10)
echo "$DEVICES_RAW"
echo ""

# Extract clean device names (remove the [AVFoundation ...] prefix)
DEVICE_NAMES=$(echo "$DEVICES_RAW" | sed 's/.*\] //' | sed 's/\[.*//')

# Try to auto-detect the built-in mic (check various Mac types)
DEFAULT_MIC=""
for mic in "MacBook Pro Microphone" "MacBook Air Microphone" "iMac Microphone" "Mac Mini Microphone" "Mac Studio Microphone" "Mac Pro Microphone" "Built-in Microphone"; do
    if echo "$DEVICE_NAMES" | grep -q "$mic"; then
        DEFAULT_MIC="$mic"
        break
    fi
done

if [[ -n "$DEFAULT_MIC" ]]; then
    info "Detected built-in microphone: ${BOLD}$DEFAULT_MIC${NC}"
    read -p "Use this microphone? [Y/n]: " USE_DEFAULT
    USE_DEFAULT=${USE_DEFAULT:-Y}
    if [[ "$USE_DEFAULT" =~ ^[Yy]$ ]]; then
        MIC_NAME="$DEFAULT_MIC"
    else
        echo ""
        echo "Enter the microphone name EXACTLY as shown in the list above."
        echo "Copy and paste it to avoid typos."
        read -p "Microphone name: " MIC_NAME
    fi
else
    warn "Could not auto-detect a built-in microphone."
    echo ""
    echo "Enter the microphone name EXACTLY as shown in the list above."
    echo "Copy and paste it to avoid typos."
    read -p "Microphone name: " MIC_NAME
fi

# Verify the microphone name was captured
if [[ -z "$MIC_NAME" ]]; then
    error "No microphone name provided. Please run the installer again."
fi

info "Using microphone: ${BOLD}$MIC_NAME${NC}"

# ============================================================================
step "8/8" "Installing the script"
# ============================================================================

HAMMERSPOON_DIR="$HOME/.hammerspoon"

mkdir -p "$HAMMERSPOON_DIR"

# Copy init.lua and update settings
cp "$SCRIPT_DIR/init.lua" "$HAMMERSPOON_DIR/init.lua"

# Update the microphone name in the config
sed -i '' "s|local inputDevice = \"none:.*\"|local inputDevice = \"none:$MIC_NAME\"|" "$HAMMERSPOON_DIR/init.lua"

# Update the model path if not using the default
if [[ "$MODEL_NAME" != "large-v3-turbo" ]]; then
    sed -i '' "s|ggml-large-v3-turbo.bin|ggml-$MODEL_NAME.bin|" "$HAMMERSPOON_DIR/init.lua"
fi

success "Script installed to ~/.hammerspoon/init.lua"

# ============================================================================
# Done!
# ============================================================================

echo ""
echo -e "${BOLD}${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║                    🎉 Installation Complete!                   ║${NC}"
echo -e "${BOLD}${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "📋 Next steps:"
echo ""
echo "   1. ${BOLD}Open Hammerspoon${NC}"
echo "      └─ Find it in Applications or Spotlight (Cmd+Space, type 'Hammerspoon')"
echo ""
echo "   2. ${BOLD}Grant Accessibility permission${NC}"
echo "      └─ When prompted, go to System Settings → Privacy & Security → Accessibility"
echo "      └─ Enable Hammerspoon"
echo ""
echo "   3. ${BOLD}Grant Microphone permission${NC}"
echo "      └─ When you first record, macOS will ask for microphone access"
echo "      └─ Click 'Allow'"
echo ""
echo "   4. ${BOLD}Reload Hammerspoon config${NC}"
echo "      └─ Click the Hammerspoon icon in the menu bar → 'Reload Config'"
echo ""
echo "🎙️ ${BOLD}How to use:${NC}"
echo ""
echo "   • Hold ${BOLD}⌥⌘V${NC} (Option+Command+V) and speak"
echo "   • Release to transcribe and paste"
echo ""
echo "   Other hotkeys:"
echo "   • ${BOLD}⌥⌘E${NC} = English only"
echo "   • ${BOLD}⌥⌘C${NC} = Russian only"
echo ""
success "You're all set! Enjoy hands-free typing 🚀"
