#!/bin/bash
# Build the bundled model server from the pinned llama.cpp source.
# Usage: scripts/build-model-server.sh LLAMA_CPP_CHECKOUT OUTPUT_BINARY   (needs cmake and ninja on PATH)
set -euo pipefail
cd "$(dirname "$0")/.."
SOURCE="$1"; OUTPUT="$2"
PIN=Integrations/Model/PIN.json
COMMIT=$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["commit"])' "$PIN")
[ "$(git -C "$SOURCE" rev-parse HEAD)" = "$COMMIT" ] || { printf 'llama.cpp checkout is not at the pinned commit %s\n' "$COMMIT" >&2; exit 1; }
[ -z "$(git -C "$SOURCE" status --porcelain --untracked-files=no)" ] || { printf 'llama.cpp checkout has local changes\n' >&2; exit 1; }
FLAGS=$(/usr/bin/python3 -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1]))["cmake"]))' "$PIN")
BUILD="$SOURCE/build-planisphere"
# shellcheck disable=SC2086
cmake -S "$SOURCE" -B "$BUILD" -G Ninja $FLAGS
cmake --build "$BUILD" --target llama-server
mkdir -p "$(dirname "$OUTPUT")"
cp "$BUILD/bin/llama-server" "$OUTPUT"
"$OUTPUT" --version 2>&1 | grep -q "commit ${COMMIT:0:7}" || { printf 'built server does not report the pinned commit\n' >&2; exit 1; }
printf 'Built %s from llama.cpp %s\n' "$OUTPUT" "${COMMIT:0:7}"
