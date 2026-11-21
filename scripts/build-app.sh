#!/usr/bin/env bash
# Builds the release app bundle build/Squeeze7z.app with the vendored 7zz engine,
# the app icon (Icon Composer document compiled with actool, plus an .icns fallback)
# and the 7-Zip license, then ad-hoc signs it.
#
# Usage: scripts/build-app.sh [--install] [--skip-build]
#   --install     also copy the bundle to ~/Applications/Squeeze7z.app
#   --skip-build  reuse the existing release binary (assembly and signing only)

set -euo pipefail

readonly APP_NAME="Squeeze7z"
readonly BUNDLE_ID="org.zermat.squeeze7z"
# SQUEEZE7Z_VERSION and SQUEEZE7Z_FEED_URL override these, for scripts/release.sh and for local update tests.
readonly VERSION="${SQUEEZE7Z_VERSION:-0.2.0}"
# Sparkle compares CFBundleVersion, so it follows the version.
readonly BUILD_NUMBER="${VERSION}"
readonly FEED_URL="${SQUEEZE7Z_FEED_URL:-https://raw.githubusercontent.com/Camponotus-vagus/Squeeze7z/main/appcast.xml}"
# Public half of the EdDSA key that signs update archives (the private half is in the release machine's Keychain).
readonly UPDATE_PUBLIC_KEY="ZH3hWymCV33kYDAZcNTlkdrX0qnzzQNPveJsOeZuvq8="
readonly MIN_MACOS="26.0"
readonly COPYRIGHT="Copyright 2026 Zermat. 7-Zip engine by Igor Pavlov (LGPL, unRAR restriction)."

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly BUILD_DIR="${REPO_ROOT}/build"
readonly APP_DIR="${BUILD_DIR}/${APP_NAME}.app"
readonly CONTENTS_DIR="${APP_DIR}/Contents"
readonly MACOS_DIR="${CONTENTS_DIR}/MacOS"
readonly FRAMEWORKS_DIR="${CONTENTS_DIR}/Frameworks"
readonly RESOURCES_DIR="${CONTENTS_DIR}/Resources"
readonly ENGINE_SRC="${REPO_ROOT}/Vendor/7zip/7zz"
readonly LICENSE_SRC="${REPO_ROOT}/Vendor/7zip/License.txt"
# The Liquid Glass icon (scripts/make-icon.swift writes both files from the same artwork).
readonly ICON_DOCUMENT="${REPO_ROOT}/Resources/AppIcon.icon"
readonly ICON_FALLBACK="${REPO_ROOT}/Resources/AppIcon.icns"

install_app=false
skip_build=false
for arg in "$@"; do
    case "${arg}" in
        --install) install_app=true ;;
        --skip-build) skip_build=true ;;
        -h|--help)
            sed -n '2,8p' "${BASH_SOURCE[0]}"
            exit 0
            ;;
        *)
            echo "error: unknown argument '${arg}'" >&2
            exit 2
            ;;
    esac
done

log() {
    echo "==> $*"
}

require_file() {
    if [[ ! -f "$1" ]]; then
        echo "error: missing file $1" >&2
        exit 1
    fi
}

cd "${REPO_ROOT}"

require_file "${ENGINE_SRC}"
require_file "${LICENSE_SRC}"
require_file "${ICON_DOCUMENT}/icon.json"
require_file "${ICON_FALLBACK}"

# SQUEEZE7Z_APP_BUNDLE leaves out the #filePath lookups of a checkout, so the app does not carry the path of the
# machine it was built on. The bundle finds 7zz and its license as resources.
# The rpath lets the executable find Sparkle.framework in Contents/Frameworks.
readonly APP_FLAGS=(-Xswiftc -DSQUEEZE7Z_APP_BUNDLE -Xlinker -rpath -Xlinker @executable_path/../Frameworks)

if [[ "${skip_build}" == false ]]; then
    log "Building ${APP_NAME} (release)"
    swift build -c release --product "${APP_NAME}" "${APP_FLAGS[@]}"
fi

BIN_DIR="$(swift build -c release --product "${APP_NAME}" "${APP_FLAGS[@]}" --show-bin-path)"
readonly BIN_DIR
readonly EXECUTABLE="${BIN_DIR}/${APP_NAME}"
require_file "${EXECUTABLE}"

log "Assembling ${APP_DIR}"
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

cp "${EXECUTABLE}" "${MACOS_DIR}/${APP_NAME}"
# Drop the debug symbol table: it names the source files by their absolute path on the build machine.
strip -S "${MACOS_DIR}/${APP_NAME}"
chmod 755 "${MACOS_DIR}/${APP_NAME}"
# SwiftPM also adds absolute rpaths into the build folder: they would not exist on another Mac and would name
# this one's folders.
otool -l "${MACOS_DIR}/${APP_NAME}" | awk '$1 == "path" && $2 !~ /^@/ { print $2 }' | while read -r rpath; do
    install_name_tool -delete_rpath "${rpath}" "${MACOS_DIR}/${APP_NAME}"
done

log "Embedding Sparkle.framework"
require_file "${BIN_DIR}/Sparkle.framework/Versions/B/Sparkle"
mkdir -p "${FRAMEWORKS_DIR}"
# ditto keeps the framework's symlinks and executable bits, which Sparkle needs.
ditto "${BIN_DIR}/Sparkle.framework" "${FRAMEWORKS_DIR}/Sparkle.framework"

cat > "${CONTENTS_DIR}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>${MIN_MACOS}</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Archive</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.archive</string>
                <string>public.zip-archive</string>
                <string>com.pkware.zip-archive</string>
                <string>org.7-zip.7-zip-archive</string>
                <string>com.rarlab.rar-archive</string>
                <string>public.tar-archive</string>
                <string>org.gnu.gnu-zip-archive</string>
                <string>org.gnu.gnu-zip-tar-archive</string>
                <string>public.bzip2-archive</string>
                <string>org.tukaani.xz-archive</string>
                <string>public.disk-image</string>
                <string>public.iso-image</string>
                <string>com.apple.disk-image-udif</string>
                <string>public.folder</string>
            </array>
        </dict>
    </array>
    <key>NSHumanReadableCopyright</key>
    <string>${COPYRIGHT}</string>
    <key>SUFeedURL</key>
    <string>${FEED_URL}</string>
    <key>SUPublicEDKey</key>
    <string>${UPDATE_PUBLIC_KEY}</string>
</dict>
</plist>
PLIST
plutil -lint "${CONTENTS_DIR}/Info.plist" >/dev/null

log "Compiling the app icon"
# actool turns the Icon Composer document into Assets.car (CFBundleIconName), which the system
# renders with Liquid Glass in every appearance. actool hands the work to a long-lived agent
# that may run in another directory, so every path is absolute, and it can fail without an
# error status, so the output is checked.
ICON_PARTIAL_PLIST="$(mktemp -t squeeze7z-icon)"
readonly ICON_PARTIAL_PLIST
xcrun actool "${ICON_DOCUMENT}" --compile "${RESOURCES_DIR}" --platform macosx \
    --minimum-deployment-target "${MIN_MACOS}" --app-icon AppIcon \
    --output-partial-info-plist "${ICON_PARTIAL_PLIST}" >/dev/null
rm -f "${ICON_PARTIAL_PLIST}"
require_file "${RESOURCES_DIR}/Assets.car"
# CFBundleIconFile fallback: the full-size .icns rendered by scripts/make-icon.swift replaces
# the reduced one that actool writes next to Assets.car.
cp "${ICON_FALLBACK}" "${RESOURCES_DIR}/AppIcon.icns"
# cp -p keeps the executable bit of the vendored engine.
cp -p "${ENGINE_SRC}" "${RESOURCES_DIR}/7zz"
chmod 755 "${RESOURCES_DIR}/7zz"
cp "${LICENSE_SRC}" "${RESOURCES_DIR}/7zip-License.txt"

log "Signing (ad-hoc)"
# Sign the nested engine and Sparkle (with its helper apps and XPC services) first, then the bundle as a whole.
codesign --force -s - "${RESOURCES_DIR}/7zz"
codesign --force --deep -s - "${FRAMEWORKS_DIR}/Sparkle.framework"
codesign --force --deep -s - "${APP_DIR}"
codesign -v --strict --verbose=2 "${APP_DIR}"

if [[ "${install_app}" == true ]]; then
    readonly INSTALL_DIR="${HOME}/Applications"
    log "Installing to ${INSTALL_DIR}/${APP_NAME}.app"
    mkdir -p "${INSTALL_DIR}"
    rm -rf "${INSTALL_DIR}/${APP_NAME}.app"
    ditto "${APP_DIR}" "${INSTALL_DIR}/${APP_NAME}.app"
fi

log "Done: ${APP_DIR}"
