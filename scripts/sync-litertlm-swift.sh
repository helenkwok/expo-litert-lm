#!/usr/bin/env bash
# sync-litertlm-swift.sh
# Fetches rewrapped LiteRTLM-Swift xcframeworks from the fork's GitHub Release
# by tag, verifies SHA-256 against rewrap-manifest.json, places artifacts
# under ios/BinaryPods/Frameworks/, bumps package.json version, copies manifest.
#
# Manual sync only — this script does NOT auto-commit. Operator reviews and
# commits explicitly: ios/BinaryPods/Frameworks/rewrap-manifest.json +
# package.json + package-lock.json + CHANGELOG.md. Do NOT commit the
# .xcframework binaries (gitignored).
#
# Requires: gh CLI authenticated as a user with read access to helenkwok/LiteRTLM-Swift
# Requires: jq, shasum (macOS), npm (for version bump), unzip
#
# Usage:
#   scripts/sync-litertlm-swift.sh <tag>
#   e.g. scripts/sync-litertlm-swift.sh v0.7.3+rewrap.1
#
# Phase 14 D-34, D-35

set -euo pipefail

TAG="${1:-}"
[ -n "$TAG" ] || { echo "usage: $0 <tag>  (e.g. v0.7.3+rewrap.1)" >&2; exit 1; }

REPO="helenkwok/LiteRTLM-Swift"
DEST="ios/BinaryPods/Frameworks"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> Syncing LiteRTLM-Swift $TAG from $REPO into $DEST/"

# 1. Fetch manifest FIRST — it is the trust anchor for ALL xcframeworks.
#    Paying manifest bandwidth before xcframework bandwidth allows SHA verification
#    before downloading the (large) xcframework zips.
tmpdir=$(mktemp -d)
trap "rm -rf $tmpdir" EXIT

echo "  Fetching rewrap-manifest.json..."
gh release download "$TAG" --repo "$REPO" --pattern 'rewrap-manifest.json' --dir "$tmpdir"
manifest="$tmpdir/rewrap-manifest.json"

schema_version=$(jq -r .schema_version "$manifest")
[ "$schema_version" = "1" ] || {
  echo "FAIL: unexpected manifest schema_version=$schema_version (expected 1)" >&2
  exit 1
}

count=$(jq '.xcframeworks | length' "$manifest")
[ "$count" -ge 2 ] || {
  echo "FAIL: manifest.xcframeworks has $count entries, expected >=2 (CLiteRTLM + GemmaModelConstraintProvider)" >&2
  exit 1
}

echo "  Manifest OK: schema_version=$schema_version, $count xcframeworks"

# 2. For EACH xcframework entry: fetch zip, verify SHA-256, unzip into DEST.
mkdir -p "$DEST"

jq -c '.xcframeworks[]' "$manifest" | while read -r entry; do
  name=$(echo "$entry"         | jq -r .name)
  zip_filename=$(echo "$entry" | jq -r .zip_filename)
  expected_sha=$(echo "$entry" | jq -r .zip_sha256)

  # Validate expected sha is 64-hex (guards against manifest with placeholder)
  if ! [[ "$expected_sha" =~ ^[0-9a-f]{64}$ ]]; then
    echo "FAIL: manifest entry '$name' has non-hex zip_sha256: '$expected_sha'" >&2
    exit 1
  fi

  echo "  Fetching $zip_filename..."
  gh release download "$TAG" --repo "$REPO" --pattern "$zip_filename" --dir "$tmpdir"

  actual_sha=$(shasum -a 256 "$tmpdir/$zip_filename" | awk '{print $1}')
  if [ "$actual_sha" != "$expected_sha" ]; then
    echo "FAIL: sha256 mismatch for $name" >&2
    echo "  expected: $expected_sha" >&2
    echo "  actual:   $actual_sha" >&2
    exit 1
  fi

  echo "  ✓ $name sha256 verified (${expected_sha:0:12}...)"

  # Remove existing xcframework if present, then unzip
  rm -rf "$DEST/$name"
  unzip -q "$tmpdir/$zip_filename" -d "$DEST"

  if [ ! -d "$DEST/$name" ]; then
    echo "FAIL: expected $DEST/$name after unzip of $zip_filename" >&2
    echo "  Contents of $DEST after unzip:" >&2
    ls "$DEST/" >&2
    exit 1
  fi

  echo "  ✓ $name installed at $DEST/$name"
done

# 3. Copy manifest into source-controlled location (single SoT on Pod side).
#    The manifest is the trust anchor and MUST be checked into source control.
#    The xcframework binaries are gitignored.
cp "$manifest" "$DEST/rewrap-manifest.json"
echo "  ✓ rewrap-manifest.json written to $DEST/rewrap-manifest.json"

# 4. Bump package.json version (per D-35, D-16).
upstream_ver=$(jq -r .upstream_version "$manifest")
rewrap_iter=$(jq -r .rewrap_iteration "$manifest")
# e.g. 0.2.0-litertlm.0.7.3.r1
new_pkg_ver="0.2.0-litertlm.${upstream_ver#v}.r${rewrap_iter}"
echo "  Bumping package.json version to $new_pkg_ver..."
npm version "$new_pkg_ver" --no-git-tag-version

# 5. Append CHANGELOG entry
first_sha=$(jq -r '.xcframeworks[0].zip_sha256' "$manifest")
date_str=$(date -u +"%Y-%m-%d")
echo "${date_str} — synced rewrapped LiteRTLM-Swift $TAG ($count xcframeworks, first sha256: ${first_sha:0:12}...)" >> CHANGELOG.md
echo "  ✓ CHANGELOG.md updated"

echo ""
echo "==> Sync complete."
echo ""
echo "Files to COMMIT (manual review first):"
echo "  $DEST/rewrap-manifest.json  (trust anchor — MUST be committed)"
echo "  package.json                (version bumped to $new_pkg_ver)"
echo "  package-lock.json           (version bumped to $new_pkg_ver)"
echo "  CHANGELOG.md                (sync entry added)"
echo ""
echo "Files to NOT COMMIT (gitignored binaries):"
jq -r '.xcframeworks[].name' "$manifest" | while read -r xcf; do
  echo "  $DEST/$xcf"
done
echo ""
echo "Suggested commit message:"
echo "  chore(sync): rewrapped LiteRTLM-Swift $TAG ($count xcframeworks)"
