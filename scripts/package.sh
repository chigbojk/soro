#!/usr/bin/env bash
# scripts/package.sh - Build Soro.app (Release) and create dist/Soro.dmg
#
# Usage:
#   ./scripts/package.sh
#
# Signing (portable by default):
#   Builds ad-hoc ("-") with no team so a plain clone works out of the box.
#   For a stable Apple Development identity (keeps Mic/Accessibility grants
#   across rebuilds), export before running:
#     export SORO_SIGN_ID="Apple Development: Your Name (XXXXXXXXXX)"
#     export SORO_TEAM_ID="YOURTEAMID"
#
# Requirements:
#   - Xcode command-line tools (xcodebuild, hdiutil)
#   - macOS 14+
#
# Output:
#   dist/Soro.dmg  -- drag-to-install DMG containing Soro.app + INSTALL.txt

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$REPO_ROOT/Soro.xcodeproj"
SCHEME="Soro"
CONFIGURATION="Release"
BUILD_DIR="$REPO_ROOT/build"
DERIVED_DATA="$BUILD_DIR/DerivedData"
DIST_DIR="$REPO_ROOT/dist"
DMG_NAME="Soro"
DMG_PATH="$DIST_DIR/${DMG_NAME}.dmg"
STAGING_DIR="$BUILD_DIR/dmg-staging"
INSTALL_TXT="$STAGING_DIR/INSTALL.txt"

echo "==> Soro packaging script"
echo "    Project : $PROJECT"
echo "    Scheme  : $SCHEME"
echo "    Config  : $CONFIGURATION"
echo ""

# 1. Clean previous build artifacts
echo "==> Cleaning previous build..."
rm -rf "$BUILD_DIR" "$DIST_DIR"
mkdir -p "$BUILD_DIR" "$DIST_DIR" "$STAGING_DIR"

# 2. Build Release app.
# Signing is portable: ad-hoc ("-") with no team by default so anyone can build.
# Override SORO_SIGN_ID / SORO_TEAM_ID for a stable Apple Development identity
# so macOS TCC (Microphone / Accessibility) permissions persist across rebuilds
# instead of resetting on every ad-hoc cdhash change. Hardened runtime stays OFF.
SIGN_ID="${SORO_SIGN_ID:--}"
TEAM_ID="${SORO_TEAM_ID:-}"
echo "==> Building ${SCHEME} (Release, signed: ${SIGN_ID})..."
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGN_IDENTITY="$SIGN_ID" \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    ENABLE_HARDENED_RUNTIME=NO \
    ONLY_ACTIVE_ARCH=NO \
    build \
    | grep -E "^(error:|Build succeeded|BUILD FAILED|CompileSwift|Ld )" || true

APP_SRC="$DERIVED_DATA/Build/Products/${CONFIGURATION}/Soro.app"
if [[ ! -d "$APP_SRC" ]]; then
    echo "ERROR: Build product not found at $APP_SRC"
    exit 1
fi
echo "    Built:  $APP_SRC"

# 3. Copy app into staging folder
echo "==> Staging app..."
cp -R "$APP_SRC" "$STAGING_DIR/Soro.app"

# 4. Write INSTALL.txt
cat > "$INSTALL_TXT" << 'INSTALL'
==========================================================
  Soro -- 100% On-Device Dictation for macOS
==========================================================

FIRST-TIME INSTALL
------------------
1. Drag Soro.app to your /Applications folder.

2. Remove the quarantine attribute (required for unsigned apps):
      xattr -dr com.apple.quarantine /Applications/Soro.app

3. Right-click Soro.app -> Open -> click "Open" in the dialog.

PERMISSIONS (required once)
----------------------------
* Microphone: grant when prompted on first launch.
* Accessibility: System Settings > Privacy & Security > Accessibility
  -> enable Soro. Required for the global hotkey.

OLLAMA (optional -- for AI cleanup & style matching)
-----------------------------------------------------
  brew install ollama
  ollama pull llama3.2:3b
  ollama serve

Soro works in raw-transcript mode without Ollama.

BASIC USE
---------
* Hold Left Option to dictate; release to insert.
* Double-tap Left Option to lock hands-free; tap once to stop.
* The onboarding wizard runs automatically on first launch.

SECOND-MAC INSTALL
------------------
Copy Soro.app to the target Mac, then repeat steps 2-3 above.
No license, no account, no internet connection required.

==========================================================
INSTALL

echo "    INSTALL.txt written."

# 5. Create DMG
echo "==> Creating DMG at ${DMG_PATH}..."
hdiutil create \
    -volname "$DMG_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

echo ""
echo "==> Done."
echo "    DMG : ${DMG_PATH}"
echo "    Size: $(du -sh "${DMG_PATH}" | cut -f1)"

# 6. Smoke-test: mount DMG and verify Soro.app is inside
echo ""
echo "==> Smoke-testing DMG..."
MOUNT_POINT="$BUILD_DIR/dmg-mount"
mkdir -p "$MOUNT_POINT"
hdiutil attach "${DMG_PATH}" -mountpoint "$MOUNT_POINT" -nobrowse -quiet

if [[ -d "$MOUNT_POINT/Soro.app" ]]; then
    echo "    Soro.app found inside DMG."
else
    echo "ERROR: Soro.app not found inside mounted DMG!"
    hdiutil detach "$MOUNT_POINT" -quiet || true
    exit 1
fi

hdiutil detach "$MOUNT_POINT" -quiet

echo ""
echo "==> Package complete: ${DMG_PATH}"
echo ""
echo "    To install on this Mac:"
echo "      cp -R dist/Soro.app /Applications/"
echo "      xattr -dr com.apple.quarantine /Applications/Soro.app"
echo "      open /Applications/Soro.app"
