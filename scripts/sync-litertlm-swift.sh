#!/usr/bin/env bash
# sync-litertlm-swift.sh
# Manual sync from helenkwok/LiteRTLM-Swift fork into vendored copies under
# expo-litert-lm/ios/. Pulls the source xcframework + Swift sources, runs the
# fork's scripts/rewrap-xcframework.sh, and copies the rewrapped outputs into
# place. Version bumps and CHANGELOG entries are manual per offlineaid D-16.
#
# Usage:
#   scripts/sync-litertlm-swift.sh [REF]                 # clone fork at REF (default: main)
#   LITERTLM_SWIFT_LOCAL_PATH=/path scripts/sync-litertlm-swift.sh  # use local fork checkout

set -euo pipefail

REF="${1:-main}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG_VERSION="$(node -p "require('${ROOT}/package.json').version")"
export LITERTLM_VERSION="${PKG_VERSION%-*}"   # strip any -dev.N suffix for the xcframework Info.plist
export LITERTLM_BUILD="1"

echo "==> Sync helenkwok/LiteRTLM-Swift -> expo-litert-lm/ios/ (ref=${REF}, version=${LITERTLM_VERSION})"

# 1. Resolve fork source (clone or local path)
if [ -n "${LITERTLM_SWIFT_LOCAL_PATH:-}" ]; then
  FORK_DIR="$LITERTLM_SWIFT_LOCAL_PATH"
  if [ ! -d "$FORK_DIR" ]; then
    echo "ERROR: LITERTLM_SWIFT_LOCAL_PATH=$FORK_DIR does not exist" >&2
    exit 1
  fi
  echo "==> Using local fork: $FORK_DIR"
  CLEANUP=""
else
  TMP="$(mktemp -d)"
  FORK_DIR="$TMP/fork"
  echo "==> Cloning helenkwok/LiteRTLM-Swift @ ${REF} into $FORK_DIR"
  git clone --depth 1 --branch "$REF" \
    https://github.com/helenkwok/LiteRTLM-Swift.git "$FORK_DIR"
  CLEANUP="$TMP"
fi

# 2. Run the fork's rewrap script (idempotent — emits sibling -rewrapped + GMCP xcframeworks)
(cd "$FORK_DIR" && ./scripts/rewrap-xcframework.sh Frameworks/LiteRTLM.xcframework >/dev/null)

REWRAPPED="$FORK_DIR/Frameworks/LiteRTLM-rewrapped.xcframework"
GMCP="$FORK_DIR/Frameworks/GemmaModelConstraintProvider.xcframework"

[ -d "$REWRAPPED" ] || { echo "ERROR: rewrap did not produce $REWRAPPED" >&2; exit 1; }
[ -d "$GMCP" ] || { echo "ERROR: rewrap did not produce $GMCP" >&2; exit 1; }

# 3. Stage vendored copies
DEST_FW="$ROOT/ios/Frameworks"
DEST_SRC="$ROOT/ios/Sources"
mkdir -p "$DEST_FW" "$DEST_SRC"

# Drop the -rewrapped suffix so podspec references stay clean (D-15 — vendored
# copy is authoritative).
rm -rf "$DEST_FW/CLiteRTLM.xcframework" "$DEST_FW/GemmaModelConstraintProvider.xcframework"
cp -R "$REWRAPPED" "$DEST_FW/CLiteRTLM.xcframework"
cp -R "$GMCP" "$DEST_FW/GemmaModelConstraintProvider.xcframework"

rm -rf "$DEST_SRC/LiteRTLMSwift"
cp -R "$FORK_DIR/Sources/LiteRTLMSwift" "$DEST_SRC/LiteRTLMSwift"

# 4. Tree summary
echo ""
echo "==> Vendored copy summary:"
find "$DEST_FW" "$DEST_SRC" -maxdepth 3 -type d | sed "s|$ROOT/||"
echo ""
du -sh "$DEST_FW"/*.xcframework "$DEST_SRC/LiteRTLMSwift" 2>/dev/null

# 5. Cleanup temp clone
[ -n "$CLEANUP" ] && rm -rf "$CLEANUP"

echo ""
echo "REMINDER: bump package.json version + add CHANGELOG entry before publishing — see offlineaid CONTEXT D-16."
