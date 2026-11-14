#!/usr/bin/env bash
#
# Builds and runs the CopyQSync probe.
#
# Uses only the macOS Command Line Tools (`swiftc`), no Xcode project and no
# SwiftPM manifest. By default, builds go to ${TMPDIR:-/tmp}/copyq-sync-build;
# set COPYQ_SYNC_BUILD_DIR to override the build directory.
#
# Usage:
#   tools/copyq-sync-probe.sh sweep <sync-folder> [...]
#   tools/copyq-sync-probe.sh roundtrip <path> [...]
#   tools/copyq-sync-probe.sh cpq <archive.cpq>

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
    -o "${build_dir}/copyq-sync-probe" \
    "${sources[@]}" \
    "${repo}/core/CopyQSync/Probe/main.swift"

exec "${build_dir}/copyq-sync-probe" "$@"
