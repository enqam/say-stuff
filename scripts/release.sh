#!/bin/bash
set -e

# Release script for SayStuff
# Usage: ./scripts/release.sh 1.0.0

VERSION=${1:-"1.0.0"}
BUILD_DIR="build"
APP_NAME="SayStuff"
ZIP_NAME="${APP_NAME}-${VERSION}.zip"

echo "Building SayStuff v${VERSION}..."

# Clean and build
xcodebuild -project SayStuff.xcodeproj \
    -scheme SayStuff \
    -configuration Release \
    -derivedDataPath "${BUILD_DIR}" \
    clean build

# Find the app
APP_PATH="${BUILD_DIR}/Build/Products/Release/${APP_NAME}.app"

if [ ! -d "$APP_PATH" ]; then
    echo "Error: App not found at ${APP_PATH}"
    exit 1
fi

# Create release directory
mkdir -p "releases"

# Create zip
echo "Creating ${ZIP_NAME}..."
cd "${BUILD_DIR}/Build/Products/Release"
zip -r -y "../../../../releases/${ZIP_NAME}" "${APP_NAME}.app"
cd ../../../../

echo ""
echo "✅ Release built: releases/${ZIP_NAME}"
echo ""
echo "Next steps:"
echo "1. Create GitHub release: gh release create v${VERSION} releases/${ZIP_NAME} --title 'v${VERSION}'"
echo "2. Update appcast.xml with new version info"
echo "3. Commit and push appcast.xml"
