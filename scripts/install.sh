#!/bin/bash
# Build and install Perch to the Applications folder.
#
# Usage: ./scripts/install.sh [--launch|-l]

set -e
cd "$(dirname "$0")/.."

APP_NAME="Perch"
BUILD_DIR="$(pwd)/build"
BUILD_PATH="$BUILD_DIR/Build/Products/Debug/Perch.app"
INSTALL_PATH="/Applications/$APP_NAME.app"

# Clean and build the app
echo "Cleaning build artifacts..."
rm -rf "$BUILD_DIR"

echo "Building $APP_NAME (full rebuild)..."
xcodebuild -scheme Perch -configuration Debug \
    -derivedDataPath "$BUILD_DIR" \
    build 2>&1 | grep -E "(error:|warning:.*error|BUILD)" || true

if [ ! -d "$BUILD_PATH" ]; then
    echo "ERROR: Build failed - no app bundle found"
    exit 1
fi
echo "Build succeeded"

# Kill running app if present
pkill -x "$APP_NAME" 2>/dev/null && echo "Stopped running $APP_NAME" && sleep 1 || true

# Remove old installation
if [ -d "$INSTALL_PATH" ]; then
    rm -rf "$INSTALL_PATH"
    echo "Removed old installation"
fi

# Copy new build
cp -R "$BUILD_PATH" "$INSTALL_PATH"
echo "Installed $APP_NAME to $INSTALL_PATH"

# Optionally launch
if [ "$1" = "--launch" ] || [ "$1" = "-l" ]; then
    open "$INSTALL_PATH"
    echo "Launched $APP_NAME"
fi
