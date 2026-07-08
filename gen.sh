#!/usr/bin/env bash
# Generate type-support code from the XL300 IDLs with Fast DDS Gen.
#   ./gen.sh              -> generate C++ type support into ./generated
#   ./gen.sh -example     -> ALSO generate a ready-to-build pub/sub demo per type
#                            (great for a first run: build it, run pub + sub, see data)
# Requires fastddsgen on PATH (see dds/README.md for install).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${HERE}/generated"
mkdir -p "${OUT}"

EXTRA=()
[[ "${1:-}" == "-example" ]] && EXTRA=( -example CMake )

for idl in common nav sensors control feedback safety health; do
  echo "[gen] ${idl}.idl"
  fastddsgen -replace -d "${OUT}" -I "${HERE}/idl" "${EXTRA[@]}" "${HERE}/idl/${idl}.idl"
done

echo "[✓] Generated into ${OUT}"
[[ ${#EXTRA[@]} -gt 0 ]] && echo "    Build a demo:  cd ${OUT} && cmake -B build && cmake --build build"
