#!/usr/bin/env bash
# Publishes a release: builds the app from a clean clone of origin/main, signs the zip for Sparkle,
# creates the GitHub release with the zip, then adds the release to appcast.xml and pushes it.
#
# Usage: scripts/release.sh VERSION NOTES.md
#   VERSION must match the default VERSION in scripts/build-app.sh, and origin/main must hold the
#   commit to release. The EdDSA private key is read from the login Keychain (account "squeeze7z").
#   The appcast is pushed last, so the feed never names a zip that is not online yet.

set -euo pipefail

readonly REPO="Camponotus-vagus/Squeeze7z"
readonly KEY_ACCOUNT="squeeze7z"
if [[ $# -ne 2 ]]; then
    sed -n '2,9p' "${BASH_SOURCE[0]}"
    exit 2
fi
readonly VERSION="$1"
NOTES="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
readonly NOTES
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
cd "${REPO_ROOT}"

log() { echo "==> $*"; }
fail() { echo "error: $*" >&2; exit 1; }

[[ -f "${NOTES}" ]] || fail "no notes file ${NOTES}"
grep -q "^readonly VERSION=\"\${SQUEEZE7Z_VERSION:-${VERSION}}\"" scripts/build-app.sh \
    || fail "scripts/build-app.sh does not have VERSION ${VERSION}"
[[ "$(git branch --show-current)" == "main" ]] || fail "not on main"
[[ -z "$(git status --porcelain)" ]] || fail "the working tree has changes"
git fetch -q origin
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || fail "main and origin/main differ: push first"
if gh release view "v${VERSION}" --repo "${REPO}" >/dev/null 2>&1; then fail "release v${VERSION} exists"; fi

swift package resolve >/dev/null
readonly SIGN_UPDATE="${REPO_ROOT}/.build/artifacts/sparkle/Sparkle/bin/sign_update"
[[ -x "${SIGN_UPDATE}" ]] || fail "missing ${SIGN_UPDATE}"

WORK="$(mktemp -d -t squeeze7z-release)"
readonly WORK
trap 'rm -rf "${WORK}"' EXIT

log "Cloning origin/main"
git clone -q "https://github.com/${REPO}.git" "${WORK}/src"
log "Testing"
(cd "${WORK}/src" && swift test >/dev/null)
log "Building ${VERSION}"
(cd "${WORK}/src" && scripts/build-app.sh >/dev/null)
readonly APP="${WORK}/src/build/Squeeze7z.app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "${APP}/Contents/Info.plist")" == "${VERSION}" ]] \
    || fail "the built app is not version ${VERSION}"
if grep -rlaq -e "${HOME}" -e "/private/var/folders" "${APP}"; then fail "the app contains a path of this Mac"; fi

readonly ZIP="${WORK}/Squeeze7z.zip"
(cd "${WORK}/src/build" && ditto -c -k --sequesterRsrc --keepParent Squeeze7z.app "${ZIP}")
SIGNATURE="$("${SIGN_UPDATE}" --account "${KEY_ACCOUNT}" "${ZIP}")"
readonly SIGNATURE
SHA="$(shasum -a 256 "${ZIP}" | cut -d' ' -f1)"
readonly SHA

log "Creating the GitHub release v${VERSION}"
cp "${NOTES}" "${WORK}/notes.md"
printf '\nSHA-256 of Squeeze7z.zip: `%s`\n' "${SHA}" >> "${WORK}/notes.md"
gh release create "v${VERSION}" "${ZIP}" --repo "${REPO}" --target main \
    --title "Squeeze7z ${VERSION}" --notes-file "${WORK}/notes.md"

log "Publishing the appcast"
python3 -I scripts/appcast.py appcast.xml "${VERSION}" \
    "https://github.com/${REPO}/releases/download/v${VERSION}/Squeeze7z.zip" "${SIGNATURE}" "${NOTES}"
git add appcast.xml
git commit -q -m "Publish ${VERSION} in the appcast"
git push -q origin main
log "Done: v${VERSION}"
