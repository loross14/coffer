#!/bin/bash
# Source this before scripts/package-mac.sh on Logan's Mac:   source scripts/release-env.sh
# It exports every PLANISPHERE_* input the packager needs and pins the sibling
# engine/host sources to the commits this tree declares, as detached worktrees
# under .build/pins (durable, ignored by git and by the Planisphere vault scope).
# Nothing here signs, uploads or installs anything.
if [ -n "${ZSH_VERSION:-}" ]; then _self=${(%):-%N}; else _self=${BASH_SOURCE[0]}; fi
REPO_ROOT="$(cd "$(dirname "$_self")/.." && pwd)"
PINS="$REPO_ROOT/.build/pins"; mkdir -p "$PINS"
SIBLINGS="${PLANISPHERE_SIBLINGS:-$(dirname "$REPO_ROOT")}"   # planisphere-build holds Grapheine/ and planisphere-api/

pin_worktree() { # repo-dir commit target
  local repo="$1" commit="$2" target="$3"
  if [ -d "$target" ] && [ "$(git -C "$target" rev-parse HEAD 2>/dev/null)" = "$commit" ]; then return 0; fi
  [ -d "$target" ] && { git -C "$repo" worktree remove --force "$target" 2>/dev/null || rm -rf "$target"; }
  git -C "$repo" cat-file -e "$commit^{commit}" 2>/dev/null || git -C "$repo" fetch -q origin
  git -C "$repo" worktree add -q --detach "$target" "$commit" || { echo "release-env: cannot pin $repo @ $commit" >&2; return 1; }
}

HOST_PIN=$(/usr/bin/python3 -c "import json;print(json.load(open('$REPO_ROOT/Integrations/Host/PIN.json'))['commit'])")
ENGINE_PIN=$(sed -n 's/^PIN = "\([0-9a-f]*\)"/\1/p' "$REPO_ROOT/scripts/bundle-grapheine.py")
pin_worktree "$SIBLINGS/planisphere-api" "$HOST_PIN" "$PINS/planisphere-api-${HOST_PIN:0:8}" && export PLANISPHERE_HOST_SOURCE="$PINS/planisphere-api-${HOST_PIN:0:8}/internal"
pin_worktree "$SIBLINGS/Grapheine" "$ENGINE_PIN" "$PINS/grapheine-${ENGINE_PIN:0:8}" && export PLANISPHERE_GRAPHEINE_SOURCE="$PINS/grapheine-${ENGINE_PIN:0:8}"

export PLANISPHERE_PYTHON_ARCHIVE="${PLANISPHERE_PYTHON_ARCHIVE:-$REPO_ROOT/.build/python-runtime.tar.gz}"
export PLANISPHERE_PYTHON_WHEELS="${PLANISPHERE_PYTHON_WHEELS:-$REPO_ROOT/.build/python-wheels}"
export PLANISPHERE_MODEL_SERVER="${PLANISPHERE_MODEL_SERVER:-/Users/logan/planisphere-releases/builtin-model-2026-10-14/model-server/planisphere-model-server}"
export PLANISPHERE_SIGN_IDENTITY="${PLANISPHERE_SIGN_IDENTITY:-Developer ID Application: Logan Ross (RA46B4WYQ4)}"
INSTALLED_PLIST="/Users/logan/Applications/Planisphere Local.app/Contents/Info.plist"
export PLANISPHERE_UPDATE_PUBLIC_KEY="${PLANISPHERE_UPDATE_PUBLIC_KEY:-$(/usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' "$INSTALLED_PLIST" 2>/dev/null)}"
export SPARKLE_BIN="$REPO_ROOT/.build/artifacts/$(basename "$REPO_ROOT")/Sparkle/bin"   # sign_update, generate_appcast (after swift package resolve)

for v in PLANISPHERE_HOST_SOURCE PLANISPHERE_GRAPHEINE_SOURCE PLANISPHERE_PYTHON_ARCHIVE PLANISPHERE_PYTHON_WHEELS PLANISPHERE_MODEL_SERVER; do
  val=$(eval "printf '%s' \"\${$v:-}\""); [ -e "$val" ] || echo "release-env: missing $v=$val" >&2
done
[ -n "${PLANISPHERE_UPDATE_PUBLIC_KEY:-}" ] || echo "release-env: missing PLANISPHERE_UPDATE_PUBLIC_KEY (read from the installed app's Info.plist)" >&2
echo "release-env: host $HOST_PIN engine $ENGINE_PIN sign '$PLANISPHERE_SIGN_IDENTITY' feed-key ${PLANISPHERE_UPDATE_PUBLIC_KEY:0:8}…"
