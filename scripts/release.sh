#!/bin/bash
set -euo pipefail

# Release script for SayStuff
# Usage: ./scripts/release.sh 0.5.0

VERSION="${1:-"0.5.1"}"
APP_NAME="SayStuff"

# Where to place artifacts (relative to repo root)
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"
RELEASES_DIR="${ROOT_DIR}/releases"

ZIP_NAME="${APP_NAME}-${VERSION}.zip"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"

# Set SIGN=1 to keep Xcode signing settings.
# Default disables signing so the script works out-of-the-box on any Mac with Xcode.
SIGN="${SIGN:-0}"

# Set UNIVERSAL=0 to build for only the host architecture.
# Default builds a universal app (arm64 + x86_64) so you can share one DMG to any Mac.
UNIVERSAL="${UNIVERSAL:-1}"

# Set BUNDLE_WHISPER=0 to skip bundling whisper-cli into the app.
BUNDLE_WHISPER="${BUNDLE_WHISPER:-1}"
# Optionally point to a specific whisper-cli to bundle.
WHISPER_CLI_PATH="${WHISPER_CLI_PATH:-""}"
# Optionally point to a whisper.cpp checkout (used to build a universal whisper-cli when needed).
WHISPER_CPP_DIR="${WHISPER_CPP_DIR:-""}"

echo "Building SayStuff v${VERSION}..."

# Build args: disable codesign by default so we can safely inject the bundled whisper-cli.
XCODE_SIGN_ARGS=()
if [ "${SIGN}" != "1" ]; then
    XCODE_SIGN_ARGS+=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="")
fi

# Build a universal app by default (avoids "arm64-only" builds from the host destination).
XCODE_DESTINATION_ARGS=()
if [ "${UNIVERSAL}" = "1" ]; then
    XCODE_DESTINATION_ARGS+=(-destination "generic/platform=macOS")
fi

# Clean and build
xcodebuild -project "${ROOT_DIR}/SayStuff.xcodeproj" \
    -scheme SayStuff \
    -configuration Release \
    -derivedDataPath "${BUILD_DIR}" \
    "${XCODE_DESTINATION_ARGS[@]}" \
    clean build \
    "${XCODE_SIGN_ARGS[@]}"

# Find the app
APP_PATH="${BUILD_DIR}/Build/Products/Release/${APP_NAME}.app"

if [ ! -d "$APP_PATH" ]; then
    echo "Error: App not found at ${APP_PATH}"
    exit 1
fi

# Optionally bundle whisper-cli into the app for non-technical installs
if [ "${BUNDLE_WHISPER}" = "1" ]; then
    echo "Bundling whisper-cli (optional)..."

    SRC=""
    if [ -n "${WHISPER_CLI_PATH}" ]; then
        SRC="${WHISPER_CLI_PATH}"
    else
        SRC="$(command -v whisper-cli || true)"
        if [ -z "${SRC}" ]; then
            for p in \
                "/usr/local/bin/whisper-cli" \
                "/opt/homebrew/bin/whisper-cli" \
                "${HOME}/whisper.cpp/build/bin/whisper-cli" \
                "${HOME}/whisper/build/bin/whisper-cli" \
                "${HOME}/.local/bin/whisper-cli"; do
                if [ -x "${p}" ]; then
                    SRC="${p}"
                    break
                fi
            done
        fi
    fi

    if [ -n "${SRC}" ] && [ -x "${SRC}" ]; then
        # If we're building a universal app, prefer a universal whisper-cli too.
        if [ "${UNIVERSAL}" = "1" ] && command -v lipo >/dev/null 2>&1; then
            ARCHS="$(lipo -archs "${SRC}" 2>/dev/null || true)"
            if [[ "${ARCHS}" != *"arm64"* || "${ARCHS}" != *"x86_64"* ]]; then
                # Try to build a universal whisper-cli from whisper.cpp if available.
                if [ -z "${WHISPER_CPP_DIR}" ] && [ -f "${HOME}/whisper.cpp/CMakeLists.txt" ]; then
                    WHISPER_CPP_DIR="${HOME}/whisper.cpp"
                fi

                if [ -n "${WHISPER_CPP_DIR}" ] && [ -f "${WHISPER_CPP_DIR}/CMakeLists.txt" ] && command -v cmake >/dev/null 2>&1; then
                    echo "  ℹ️  Found non-universal whisper-cli (${ARCHS}); building a universal one from whisper.cpp..."

                    WHISPER_BUILD_DIR="${BUILD_DIR}/whispercpp-universal"
                    if cmake -S "${WHISPER_CPP_DIR}" -B "${WHISPER_BUILD_DIR}" \
                        -DCMAKE_BUILD_TYPE=Release \
                        -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" >/dev/null \
                        && cmake --build "${WHISPER_BUILD_DIR}" --config Release >/dev/null; then

                        if [ -x "${WHISPER_BUILD_DIR}/bin/whisper-cli" ]; then
                            SRC="${WHISPER_BUILD_DIR}/bin/whisper-cli"
                            ARCHS="$(lipo -archs "${SRC}" 2>/dev/null || true)"
                            echo "  ✅ Built universal whisper-cli (${ARCHS})"
                        else
                            echo "  ⚠️  Couldn't find a built whisper-cli at ${WHISPER_BUILD_DIR}/bin/whisper-cli; bundling the original."
                        fi
                    else
                        echo "  ⚠️  Failed to build a universal whisper-cli; bundling the original."
                    fi
                else
                    echo "  ⚠️  whisper-cli isn't universal (${ARCHS})."
                    echo "     To bundle a universal one, set WHISPER_CPP_DIR=/path/to/whisper.cpp (and ensure cmake is installed)."
                fi
            fi
        fi

        mkdir -p "${APP_PATH}/Contents/Resources"
        DEST="${APP_PATH}/Contents/Resources/whisper-cli"
        cp "${SRC}" "${DEST}"
        chmod +x "${DEST}"
        echo "  ✅ Bundled: ${SRC}"
        if command -v lipo >/dev/null 2>&1; then
            lipo -info "${DEST}" 2>/dev/null || true
        fi
    else
        echo "  ⚠️  whisper-cli not found; SayStuff will require a system install of whisper.cpp."
        echo "     You can set WHISPER_CLI_PATH=/path/to/whisper-cli to bundle it."
    fi
fi

# Create release directory
mkdir -p "${RELEASES_DIR}"

# Create zip
echo "Creating ${ZIP_NAME}..."
(
    cd "${BUILD_DIR}/Build/Products/Release"
    zip -r -y "${RELEASES_DIR}/${ZIP_NAME}" "${APP_NAME}.app"
)

echo "Creating ${DMG_NAME}..."
hdiutil create -volname "${APP_NAME}" -srcfolder "${BUILD_DIR}/Build/Products/Release/${APP_NAME}.app" \
    -ov -format UDZO "${RELEASES_DIR}/${DMG_NAME}"

echo ""
echo "✅ Release built:"
echo "   - ${RELEASES_DIR}/${ZIP_NAME}"
echo "   - ${RELEASES_DIR}/${DMG_NAME}"
echo ""
echo "Next steps:"
echo "1. Create GitHub release:"
echo "   gh release create v${VERSION} \"${RELEASES_DIR}/${ZIP_NAME}\" \"${RELEASES_DIR}/${DMG_NAME}\" --title 'v${VERSION}'"
echo "2. Update appcast.xml with new version info"
echo "3. Commit and push appcast.xml"
