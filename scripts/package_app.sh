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
# SWIFT_BUILD_FLAGS lets a constrained environment add flags without editing this
# script: some sandboxes deny SwiftPM its own nested sandbox and its user-level
# cache directories, which needs --disable-sandbox plus redirected cache paths.
# Empty by default, so an ordinary developer machine is unaffected.
swift build -c release --arch arm64 ${SWIFT_BUILD_FLAGS:-}

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

# --- Bundle the plugin adapters ---
# PluginEnvironmentLocator looks for `plugins/` beside the executable during
# development and in Resources/ once packaged. Without this the packaged app
# finds no adapters and the store lists nothing installable, while the
# development build works — a discrepancy that only surfaces after shipping.
echo "Copying plugin adapters..."
rm -rf "${RESOURCES_DIR}/plugins"
mkdir -p "${RESOURCES_DIR}/plugins"
for adapter_dir in plugins/*/; do
    adapter="$(basename "${adapter_dir}")"
    # Skip development-only trees: virtualenvs are per-machine and recreated at
    # install time, and the conformance kit is a developer tool, not a runtime
    # dependency of the app.
    case "${adapter}" in
        conformance|__pycache__) continue ;;
    esac
    ditto "${adapter_dir}" "${RESOURCES_DIR}/plugins/${adapter}"
done
# Drop anything machine-specific that a developer tree accumulates, and the
# adapters' own test suites, which are developer tools rather than runtime code.
rm -rf "${RESOURCES_DIR}/plugins"/*/.venv
find "${RESOURCES_DIR}/plugins" -name "tests" -type d -prune -exec rm -rf {} +
find "${RESOURCES_DIR}/plugins" -name ".pytest_cache" -type d -prune -exec rm -rf {} +
find "${RESOURCES_DIR}/plugins" -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
find "${RESOURCES_DIR}/plugins" -name "*.pyc" -delete 2>/dev/null || true

# The manifest is the store's catalogue. SwiftPM stages it into a resource
# bundle, but the app also reads it from Resources/ so a packaged build does not
# depend on the bundle's internal layout.
echo "Copying plugin manifest..."
cp "Sources/OpenDicomViewer/Resources/plugins.json" "${RESOURCES_DIR}/"

# Fail loudly rather than shipping a store with nothing in it. The _shared
# modules are also imported by mlx-server/server.py (via ../plugins), so the
# built-in AI server cannot start without them either. Only _shared/tests is
# removed above; the package itself is always copied.
for required in "${RESOURCES_DIR}/plugins.json" \
                "${RESOURCES_DIR}/plugins/gemma/server.py" \
                "${RESOURCES_DIR}/plugins/totalseg/run_segment.py" \
                "${RESOURCES_DIR}/plugins/_shared/serve.py" \
                "${RESOURCES_DIR}/plugins/_shared/coerce.py" \
                "${RESOURCES_DIR}/plugins/_shared/errors.py" \
                "${RESOURCES_DIR}/plugins/_shared/vlm.py" \
                "${RESOURCES_DIR}/plugins/_shared/weights.py"; do
    if [ ! -f "${required}" ]; then
        echo "ERROR: ${required} missing from the bundle — the plugin store would be empty." >&2
        exit 1
    fi
done

# --- Bundle standalone Python runtime (no system Python dependency) ---
# Update these variables when a newer build is available from:
# https://github.com/astral-sh/python-build-standalone/releases
# PYTHON_SHA256 is the tarball's entry in that release's SHA256SUMS asset;
# update it together with the version and build date. The cached tarball is
# verified on every build, so a corrupted or substituted download fails here
# rather than being sealed into a signed bundle.
PYTHON_FULL_VERSION="3.11.17"
PYTHON_BUILD_DATE="20261013"
PYTHON_ARCH="aarch64"
PYTHON_TARBALL_NAME="cpython-${PYTHON_FULL_VERSION}+${PYTHON_BUILD_DATE}-${PYTHON_ARCH}-apple-darwin-install_only.tar.gz"
PYTHON_SHA256="d81d757a9785850393cd695a9a686c765a6370fbdc83738589ef2ecd3e5c44b3"
PYTHON_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PYTHON_BUILD_DATE}/${PYTHON_TARBALL_NAME}"
PYTHON_CACHE_DIR=".cache/python-standalone"
PYTHON_CACHED_TARBALL="${PYTHON_CACHE_DIR}/${PYTHON_TARBALL_NAME}"

echo "Bundling standalone Python ${PYTHON_FULL_VERSION}..."
mkdir -p "${PYTHON_CACHE_DIR}"
if [ ! -f "${PYTHON_CACHED_TARBALL}" ]; then
    echo "  Downloading from python-build-standalone..."
    curl -L --fail -o "${PYTHON_CACHED_TARBALL}.part" "${PYTHON_URL}"
    mv "${PYTHON_CACHED_TARBALL}.part" "${PYTHON_CACHED_TARBALL}"
fi

echo "  Verifying SHA-256..."
if ! echo "${PYTHON_SHA256}  ${PYTHON_CACHED_TARBALL}" | shasum -a 256 -c -; then
    echo "ERROR: ${PYTHON_CACHED_TARBALL} does not match the pinned SHA-256." >&2
    echo "       Delete it and rebuild, or update PYTHON_SHA256 from the release's SHA256SUMS." >&2
    exit 1
fi

echo "  Extracting to app bundle..."
tar xzf "${PYTHON_CACHED_TARBALL}" -C "${RESOURCES_DIR}/"
# Tarball extracts to python/ — gives us Resources/python/bin/python3 etc.

# Trim unnecessary files to reduce bundle size (~60 MB savings)
echo "  Trimming unnecessary files..."
rm -rf "${RESOURCES_DIR}/python/share"
rm -rf "${RESOURCES_DIR}/python/include"
PYLIB="${RESOURCES_DIR}/python/lib/python${PYTHON_FULL_VERSION%.*}"
rm -rf "${PYLIB}/test" "${PYLIB}/unittest/test" "${PYLIB}/lib2to3"
rm -rf "${PYLIB}/idlelib" "${PYLIB}/tkinter" "${PYLIB}/turtledemo"
# Note: keep ensurepip intact — python3 -m venv needs it to bootstrap pip
find "${RESOURCES_DIR}/python" -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
find "${RESOURCES_DIR}/python" -name "*.pyc" -delete 2>/dev/null || true

# Precompile the standard library BEFORE signing.
#
# The bundle is signed as a sealed resource set, so any file that appears
# afterwards invalidates the signature — `codesign --verify` then reports "a
# sealed resource is missing or invalid", which is a Gatekeeper rejection on a
# user's machine. The interpreter writes __pycache__ for its own stdlib the
# first time it imports a module, so the choice is to compile the bytecode now
# and seal it, or to let the app break its own signature on first launch.
# Compiling now also removes that cost from startup.
#
# `unchecked-hash` pycs are trusted as they are: the interpreter neither
# compares them with the source's mtime nor rewrites them. Timestamp pycs (the
# default) went stale -- and were rewritten inside the signed bundle -- as soon
# as a copy reset the sources' mtimes (`cp -R` into the DMG did exactly that).
#
# A compile failure fails the build: a module left without bytecode would be
# compiled on a user's machine and break the signature as described above.
echo "  Precompiling standard library (must precede signing)..."
"${RESOURCES_DIR}/python/bin/python3" -m compileall -q -f \
    --invalidation-mode unchecked-hash \
    "${RESOURCES_DIR}/python/lib/python${PYTHON_FULL_VERSION%.*}" >/dev/null

# --- Licenses ---
# The MIT license and the third-party notices (bundled CPython and its
# libraries, DCMTK, OpenJPEG, ...) travel with the binary they describe.
echo "Copying license files..."
cp "LICENSE" "${RESOURCES_DIR}/"
cp "THIRD_PARTY_LICENSES.md" "${RESOURCES_DIR}/"

# CFBundleVersion is a monotonically increasing build number derived from the
# commit count, so every build from a later commit sorts after earlier ones.
# CFBundleShortVersionString stays the marketing version.
MARKETING_VERSION="2.0.0"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

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
    <string>${MARKETING_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
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
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>DICOM Image</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Default</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>org.nema.dicom</string>
            </array>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>dcm</string>
                <string>dicom</string>
                <string>dic</string>
            </array>
        </dict>
        <dict>
            <!-- Many DICOM files have no extension; offer the app for any file
                 in "Open With" without claiming to be the default handler. -->
            <key>CFBundleTypeName</key>
            <string>DICOM File (no extension)</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.data</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>
            <string>DICOM Folder</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.folder</string>
            </array>
        </dict>
    </array>
    <key>UTImportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>org.nema.dicom</string>
            <key>UTTypeDescription</key>
            <string>DICOM Image</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.data</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>dcm</string>
                    <string>dicom</string>
                    <string>dic</string>
                </array>
                <key>public.mime-type</key>
                <array>
                    <string>application/dicom</string>
                </array>
            </dict>
        </dict>
    </array>
</dict>
</plist>
EOF

# Two entitlement sets: the bundled Python needs hardened-runtime exceptions
# (unsigned executable memory, no library validation) that the Swift executable
# does not, and granting them to the app would weaken it for nothing.
APP_ENTITLEMENTS="scripts/OpenDicomViewer.entitlements"
PYTHON_ENTITLEMENTS="scripts/Python.entitlements"

if $NOTARIZE; then
    echo "Code signing with Developer ID..."

    # 1) Sign all shared libraries inside bundled Python (innermost first)
    echo "  Signing bundled Python shared libraries..."
    find "${RESOURCES_DIR}/python" -type f \( -name "*.so" -o -name "*.dylib" \) | while read -r lib; do
        codesign --force --timestamp --options runtime --sign "${SIGNING_IDENTITY}" "$lib"
    done

    # 2) Sign Python executables with the Python-only entitlements
    echo "  Signing bundled Python executables..."
    find "${RESOURCES_DIR}/python/bin" -type f -perm +111 ! -name "*.py" | while read -r bin; do
        codesign --force --timestamp --options runtime --entitlements "${PYTHON_ENTITLEMENTS}" --sign "${SIGNING_IDENTITY}" "$bin"
    done

    # 3) Sign the main app executable with the app entitlements
    codesign --force --timestamp --options runtime --entitlements "${APP_ENTITLEMENTS}" --sign "${SIGNING_IDENTITY}" "${MACOS_DIR}/${EXECUTABLE_NAME}"

    # 4) Sign the entire app bundle. The bundle signature is written to the main
    # executable, so this must use the app entitlements too, or it would replace
    # the ones from step 3.
    codesign --force --timestamp --options runtime --entitlements "${APP_ENTITLEMENTS}" --sign "${SIGNING_IDENTITY}" "${APP_BUNDLE}"
    codesign --verify --deep --strict "${APP_BUNDLE}"
    echo "Signature OK"
else
    echo "Ad-hoc code signing (use --notarize for Developer ID signing)..."
    # Ad-hoc signatures cannot carry a secure timestamp, so no --timestamp here.
    codesign --force --deep -s - "${APP_BUNDLE}"
fi

# notarize <file>: submit to Apple's notary service and wait. notarytool can
# exit 0 for a completed submission that Apple rejected, so the final status is
# read from its output rather than trusted from the exit code alone. On failure
# the submission's log -- which names the offending file and reason -- is
# fetched before the build stops.
notarize() {
    local target="$1" output id failed=""
    echo "Submitting ${target} for notarization..."
    output="$(xcrun notarytool submit "${target}" \
        --keychain-profile "${NOTARY_PROFILE}" \
        --wait 2>&1)" || failed=1
    echo "${output}"
    id="$(echo "${output}" | awk '/^ *id:/ {print $2; exit}')"
    if [ -n "${failed}" ] || ! echo "${output}" | grep -q "status: Accepted"; then
        echo "ERROR: notarization of ${target} failed." >&2
        if [ -n "${id}" ]; then
            echo "Notary log for submission ${id}:" >&2
            xcrun notarytool log "${id}" --keychain-profile "${NOTARY_PROFILE}" >&2 || true
        fi
        exit 1
    fi
}

if $NOTARIZE; then
    # Notarize and staple the app before it goes into the DMG, so the copy a
    # user drags to /Applications carries its own ticket and passes Gatekeeper
    # offline. notarytool takes a zip, not a bare bundle.
    APP_ZIP="${DISPLAY_NAME}-notarize.zip"
    rm -f "${APP_ZIP}"
    ditto -c -k --keepParent "${APP_BUNDLE}" "${APP_ZIP}"
    notarize "${APP_ZIP}"
    rm -f "${APP_ZIP}"

    echo "Stapling ${APP_BUNDLE}..."
    xcrun stapler staple "${APP_BUNDLE}"
    xcrun stapler validate "${APP_BUNDLE}"
    echo "Checking Gatekeeper assessment of ${APP_BUNDLE}..."
    spctl -a -vvv -t exec "${APP_BUNDLE}"
fi

echo "Successfully created ${APP_BUNDLE}"

# --- Create DMG for distribution ---
DMG_NAME="${DISPLAY_NAME}.dmg"
DMG_TEMP="dmg_tmp"

echo "Creating DMG at ${DMG_NAME}..."
rm -rf "${DMG_TEMP}" "${DMG_NAME}"
mkdir -p "${DMG_TEMP}"

# ditto, not cp -R: it preserves mtimes, extended attributes and the code
# signature's resource layout exactly.
ditto "${APP_BUNDLE}" "${DMG_TEMP}/$(basename "${APP_BUNDLE}")"
ln -s /Applications "${DMG_TEMP}/Applications"

hdiutil create -volname "${DISPLAY_NAME}" \
    -srcfolder "${DMG_TEMP}" \
    -ov -format UDZO \
    "${DMG_NAME}" \
    -quiet

rm -rf "${DMG_TEMP}"

if $NOTARIZE; then
    # Sign the DMG itself so Gatekeeper can check the container's origin before
    # it is mounted, not only the app inside it.
    echo "Signing ${DMG_NAME}..."
    codesign --force --timestamp --sign "${SIGNING_IDENTITY}" "${DMG_NAME}"
    codesign --verify --strict "${DMG_NAME}"

    notarize "${DMG_NAME}"

    echo "Stapling ${DMG_NAME}..."
    xcrun stapler staple "${DMG_NAME}"
    xcrun stapler validate "${DMG_NAME}"
    echo "Checking Gatekeeper assessment of ${DMG_NAME}..."
    spctl -a -vvv -t open --context context:primary-signature "${DMG_NAME}"

    echo ""
    echo "Successfully created and notarized ${DMG_NAME}"
else
    echo ""
    echo "Successfully created ${DMG_NAME} (not notarized)"
fi
echo "To install: open ${DMG_NAME} and drag ${DISPLAY_NAME} to Applications"
