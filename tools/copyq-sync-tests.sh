#!/usr/bin/env bash
#
# Builds and runs the CopyQSync test runner.
#
# The tests use no XCTest so they run with only the macOS Command Line Tools.
# By default, builds go to ${TMPDIR:-/tmp}/copyq-sync-build; set
# COPYQ_SYNC_BUILD_DIR to override the build directory.
#
# Usage:
#   tools/copyq-sync-tests.sh
#   tools/copyq-sync-tests.sh --corpus <dir-with-_copyq.dat-copies>
#   tools/copyq-sync-tests.sh --cpq <archive.cpq>

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "${here}/.." && pwd)"

build_dir="${COPYQ_SYNC_BUILD_DIR:-${TMPDIR:-/tmp}/copyq-sync-build}"
mkdir -p "${build_dir}"

sources=("${repo}/core/QtCompression.swift" "${repo}"/core/CopyQSync/Sources/CopyQSync/*.swift)
if [ "${#sources[@]}" -eq 0 ]; then
    echo "error: no module sources found under core/CopyQSync/Sources" >&2
    exit 1
fi

swiftc -O -module-name CopyQSync -lz \
    -o "${build_dir}/copyq-sync-tests" \
    "${sources[@]}" \
    "${repo}/core/CopyQSync/Tests/main.swift"

exec "${build_dir}/copyq-sync-tests" "$@"
