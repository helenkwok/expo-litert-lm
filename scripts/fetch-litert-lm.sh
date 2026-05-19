#!/usr/bin/env bash
# fetch-litert-lm.sh
# Downloads Google's first-party CLiteRTLM.xcframework from
# google-ai-edge/LiteRT-LM GitHub Releases, verifies SHA-256, and places it
# under ios/BinaryPods/Frameworks/.
#
# Replaces sync-litertlm-swift.sh (community fork + rewrap flow), which is
# retired with the v0.12.0 spike (feat/litert-v0.12).
#
# Requires: curl, shasum (macOS), unzip
#
# Usage:
#   scripts/fetch-litert-lm.sh
#
# To bump the upstream version, edit LITERT_LM_TAG and EXPECTED_SHA256 below.

set -euo pipefail

LITERT_LM_TAG="v0.12.0"
EXPECTED_SHA256="3c2a11ecc8511d1e74efa7ca308dc7130c95223325c33212337ffb0563b79cde"
ASSET="CLiteRTLM.xcframework.zip"
URL="https://github.com/google-ai-edge/LiteRT-LM/releases/download/${LITERT_LM_TAG}/${ASSET}"

DEST="ios/BinaryPods/Frameworks"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> Fetching LiteRT-LM ${LITERT_LM_TAG} CLiteRTLM.xcframework"
echo "    Source:   ${URL}"
echo "    Dest:     ${DEST}/CLiteRTLM.xcframework"
echo "    Expected: sha256 ${EXPECTED_SHA256}"

tmpdir=$(mktemp -d)
trap "rm -rf $tmpdir" EXIT

echo "  Downloading ${ASSET}..."
curl -L -f --progress-bar "$URL" -o "$tmpdir/$ASSET"

actual_sha=$(shasum -a 256 "$tmpdir/$ASSET" | awk '{print $1}')
if [ "$actual_sha" != "$EXPECTED_SHA256" ]; then
  echo "ERROR: SHA-256 mismatch for $ASSET" >&2
  echo "  expected: $EXPECTED_SHA256" >&2
  echo "  actual:   $actual_sha" >&2
  exit 2
fi
echo "  SHA-256 OK"

echo "  Extracting..."
mkdir -p "$DEST"
rm -rf "$DEST/CLiteRTLM.xcframework"
unzip -q "$tmpdir/$ASSET" -d "$DEST"

if [ ! -d "$DEST/CLiteRTLM.xcframework" ]; then
  echo "ERROR: $DEST/CLiteRTLM.xcframework missing after unzip" >&2
  exit 3
fi

echo ""
echo "==> Done. CLiteRTLM.xcframework v${LITERT_LM_TAG#v} ready at $DEST/"
echo "    Next: cd example && npx expo prebuild --clean && bundle exec pod install"
