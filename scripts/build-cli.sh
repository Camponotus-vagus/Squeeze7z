#!/usr/bin/env bash
# Builds the release command-line tool build/squeeze7z-cli.
# The CLI finds the vendored 7zz through the checkout path (see SevenZipTool.locate).
#
# Usage: scripts/build-cli.sh

set -euo pipefail

readonly PRODUCT="squeeze7z-cli"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly BUILD_DIR="${REPO_ROOT}/build"
readonly OUTPUT="${BUILD_DIR}/${PRODUCT}"

if [[ $# -gt 0 ]]; then
    case "$1" in
        -h|--help)
            sed -n '2,6p' "${BASH_SOURCE[0]}"
            exit 0
            ;;
        *)
            echo "error: unknown argument '$1'" >&2
            exit 2
            ;;
    esac
fi

cd "${REPO_ROOT}"

echo "==> Building ${PRODUCT} (release)"
swift build -c release --product "${PRODUCT}"

BIN_DIR="$(swift build -c release --product "${PRODUCT}" --show-bin-path)"
readonly BIN_DIR
if [[ ! -x "${BIN_DIR}/${PRODUCT}" ]]; then
    echo "error: missing executable ${BIN_DIR}/${PRODUCT}" >&2
    exit 1
fi

mkdir -p "${BUILD_DIR}"
cp "${BIN_DIR}/${PRODUCT}" "${OUTPUT}"
chmod 755 "${OUTPUT}"

echo "==> Done: ${OUTPUT}"
