#!/usr/bin/env bash
# Generate type-support code from the XL300 IDLs with Fast DDS Gen.
#   ./gen.sh              -> generate C++ type support into ./generated
#   ./gen.sh -example     -> ALSO generate a ready-to-build pub/sub demo per type
#                            (great for a first run: build it, run pub + sub, see data)
# Requires fastddsgen on PATH (see dds/README.md for install).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${HERE}/generated"
# Clean re-run: fastddsgen mirrors any directory component of the INPUT path into its
# output dir (verified 2026-07-08) -- passing an absolute path like ".../dds/idl/nav.idl"
# produced generated/idl/nav.h instead of the expected flat generated/nav.h. Fix: cd into
# idl/ and pass a BARE filename, so there's no path component left to mirror. rm -rf first
# so a stale generated/idl/ from a previous run doesn't linger alongside the fixed layout.
rm -rf "${OUT}"
mkdir -p "${OUT}"

EXTRA=()
[[ "${1:-}" == "-example" ]] && EXTRA=( -example CMake )

for idl in common nav sensors control feedback safety health; do
  echo "[gen] ${idl}.idl"
  ( cd "${HERE}/idl" && fastddsgen -replace -d "${OUT}" -I . "${EXTRA[@]}" "${idl}.idl" )
done

echo "[✓] Generated into ${OUT}"
[[ ${#EXTRA[@]} -gt 0 ]] && echo "    Build a demo:  cd ${OUT} && cmake -B build && cmake --build build"
