#!/bin/bash
# package_app.sh — OpenDicomViewer-Annotate
# Builds a release binary and creates the .app bundle + DMG for distribution.
# Use --notarize to sign with Developer ID and notarize with Apple.
# Licensed under the MIT License. See LICENSE for details.
set -e

# EXECUTABLE_NAME: Swift target name (must match Package.swift)
EXECUTABLE_NAME="OpenDicomViewer"
# DISPLAY_NAME: app bundle name and DMG filename shown to users
DISPLAY_NAME="OpenDicomViewer-Annotate"
SIGNING_IDENTITY="Developer ID Application: DAESEONG KIM (58S28HKMB9)"
NOTARY_PROFILE="OpenDicomViewer"
NOTARIZE=false

if [[ "$1" == "--notarize" ]]; then
    NOTARIZE=true
fi

# Ensure we are in project root
cd "$(dirname "$0")/.."

echo "Building ${DISPLAY_NAME} (Release)..."
swift build -c release --arch arm64

BUILD_DIR=".build/release"
APP_BUNDLE="${DISPLAY_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "Creating App Bundle at ${APP_BUNDLE}..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}"
mkdir -p "${RESOURCES_DIR}"

echo "Copying Executable..."
cp "${BUILD_DIR}/${EXECUTABLE_NAME}" "${MACOS_DIR}/"

echo "Copying App Icon..."
cp "AppIcon.icns" "${RESOURCES_DIR}/"

echo "Copying DCMTK Dictionary..."
cp "libs/dcmtk/share/dcmtk-3.6.8/dicom.dic" "${RESOURCES_DIR}/"

echo "Copying mlx-server scripts..."
mkdir -p "${RESOURCES_DIR}/mlx-server"
cp "mlx-server/server.py" "${RESOURCES_DIR}/mlx-server/"
cp "mlx-server/requirements.txt" "${RESOURCES_DIR}/mlx-server/"
[ -f "mlx-server/README.md" ] && cp "mlx-server/README.md" "${RESOURCES_DIR}/mlx-server/" || true

echo "Creating Info.plist..."
cat > "${CONTENTS_DIR}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${EXECUTABLE_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>com.opendicomviewer.annotate</string>
    <key>CFBundleName</key>
    <string>${DISPLAY_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.2.0</string>
    <key>CFBundleVersion</key>
    <string>3</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>${DISPLAY_NAME} needs access to open DICOM files.</string>
    <key>NSDesktopFolderUsageDescription</key>
    <string>${DISPLAY_NAME} needs access to open DICOM files.</string>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>${DISPLAY_NAME} needs access to open DICOM files.</string>
</dict>
</plist>
EOF

if $NOTARIZE; then
    echo "Code signing with Developer ID..."
    codesign --force --options runtime --sign "${SIGNING_IDENTITY}" "${MACOS_DIR}/${EXECUTABLE_NAME}"
    codesign --force --options runtime --sign "${SIGNING_IDENTITY}" "${APP_BUNDLE}"
    codesign --verify --deep --strict "${APP_BUNDLE}"
    echo "Signature OK"
else
    echo "Ad-hoc code signing (use --notarize for Developer ID signing)..."
    codesign --force --deep -s - "${APP_BUNDLE}"
fi

echo "Successfully created ${APP_BUNDLE}"

# --- Create DMG for distribution ---
DMG_NAME="${DISPLAY_NAME}.dmg"
DMG_TEMP="dmg_tmp"

echo "Creating DMG at ${DMG_NAME}..."
rm -rf "${DMG_TEMP}" "${DMG_NAME}"
mkdir -p "${DMG_TEMP}"

cp -R "${APP_BUNDLE}" "${DMG_TEMP}/"
ln -s /Applications "${DMG_TEMP}/Applications"

hdiutil create -volname "${DISPLAY_NAME}" \
    -srcfolder "${DMG_TEMP}" \
    -ov -format UDZO \
    "${DMG_NAME}" \
    -quiet

rm -rf "${DMG_TEMP}"

if $NOTARIZE; then
    echo "Submitting ${DMG_NAME} for notarization..."
    xcrun notarytool submit "${DMG_NAME}" \
        --keychain-profile "${NOTARY_PROFILE}" \
        --wait

    echo "Stapling notarization ticket..."
    xcrun stapler staple "${DMG_NAME}"

    echo ""
    echo "Successfully created and notarized ${DMG_NAME}"
else
    echo ""
    echo "Successfully created ${DMG_NAME} (not notarized)"
fi
echo "To install: open ${DMG_NAME} and drag ${DISPLAY_NAME} to Applications"
