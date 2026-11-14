#!/usr/bin/env bash
#
# Asserts that the staged app bundle's Contents/Resources holds exactly the
# resource files of the source tree (resources/).
#
# Fails loudly naming any file sealed into the bundle that the source tree does
# not have, any source resource that never reached the bundle, and any bundled
# copy whose bytes differ from its source resource.
#
# Usage:
#   tools/assert-bundle-resources.sh [bundle-path] [source-resources-dir]

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "${here}/.." && pwd)"

bundle="${1:-${repo}/build/CopyQmac.app}"
source_dir="${2:-${repo}/resources}"

resources_dir="${bundle}/Contents/Resources"

if [ ! -d "${bundle}" ]; then
    echo "error: bundle not found at ${bundle}" >&2
    exit 1
fi

if [ ! -d "${resources_dir}" ]; then
    echo "error: bundle resources directory not found at ${resources_dir}" >&2
    exit 1
fi

if [ ! -d "${source_dir}" ]; then
    echo "error: source resources directory not found at ${source_dir}" >&2
    exit 1
fi

unexpected_count=0
while IFS= read -r -d '' file; do
    rel="${file#"${resources_dir}/"}"
    if [ ! -e "${source_dir}/${rel}" ]; then
        echo "error: bundle contains stale or untracked resource: ${rel} (not found in ${source_dir})" >&2
        unexpected_count=$((unexpected_count + 1))
    fi
done < <(find "${resources_dir}" -mindepth 1 \( -type f -o -type l \) -print0)

missing_count=0
differing_count=0
while IFS= read -r -d '' file; do
    rel="${file#"${source_dir}/"}"
    staged="${resources_dir}/${rel}"
    if [ ! -e "${staged}" ]; then
        echo "error: bundle is missing source resource: ${rel} (expected at ${staged})" >&2
        missing_count=$((missing_count + 1))
    elif ! cmp -s "${file}" "${staged}"; then
        echo "error: bundle resource differs from source: ${rel} (content does not match ${file})" >&2
        differing_count=$((differing_count + 1))
    fi
done < <(find "${source_dir}" -mindepth 1 \( -type f -o -type l \) -print0)

if [ "${unexpected_count}" -gt 0 ] || [ "${missing_count}" -gt 0 ] || [ "${differing_count}" -gt 0 ]; then
    echo "error: bundle resources do not match ${source_dir}: ${unexpected_count} unexpected, ${missing_count} missing, ${differing_count} differing" >&2
    exit 1
fi

echo "Verified bundle resources in ${resources_dir}"
