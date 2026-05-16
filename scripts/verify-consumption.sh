#!/usr/bin/env bash
# verify-consumption.sh (expo-litert-lm)
# Local runner mirroring the fork's three-layer gate structure, targeting the
# Pod consumer surface.
#
# All three layers must pass (exit 0) for the script to succeed.
# Run from repo root or via `make verify`.
#
# Layer A: `pod install` of the binary pods from a fresh consumer temp dir +
# grep Podfile.lock / generated CocoaPods support files
# Layer B: static grep for raw `LiteRTLM.xcframework` references — the upstream
# raw artifact is not consumable on iOS (App Store notary issues; Phase 14 D-24).
# The canonical rewrapped artifact is `CLiteRTLM.xcframework` (outer name matches
# the inner framework binary so CocoaPods `-framework <basename>` resolves;
# Phase 14-07 rewrap.2). Earlier iterations named the output
# `LiteRTLM-rewrapped.xcframework` — also accepted as a transitional name.
# Layer C: manifest-driven podspec consistency check
#
# Note on Layer A: requires ios/BinaryPods/Frameworks/rewrap-manifest.json + the xcframework
# binaries on disk (populated by `make sync TAG=...`). If binaries are absent,
# Layer A will fail with a CocoaPods error about missing vendored_frameworks.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

ERRORS=0
MANIFEST="$REPO_ROOT/ios/BinaryPods/Frameworks/rewrap-manifest.json"

# =============================================================================
# Layer B: static grep gate (fast — runs first)
# =============================================================================
echo ""
echo "==> Layer B: static grep gate"

ALLOWLIST="$SCRIPT_DIR/grep-allowlist.txt"
ACTIVE_PATTERNS_FILE="$(mktemp)"
trap "rm -f $ACTIVE_PATTERNS_FILE" EXIT

if [ -f "$ALLOWLIST" ]; then
  grep -vE '^(#|$)' "$ALLOWLIST" > "$ACTIVE_PATTERNS_FILE" || true
fi

set +e
raw_hits=$(grep -rnE 'LiteRTLM\.xcframework' \
  --include='*.swift' --include='*.json' --include='*.podspec' \
  --include='*.rb' --include='*.sh' --include='*.txt' \
  . 2>/dev/null \
  | grep -vE '(CLiteRTLM|LiteRTLM-rewrapped)' || true)

if [ -s "$ACTIVE_PATTERNS_FILE" ]; then
  hits=$(printf '%s\n' "$raw_hits" | grep -E -v -f "$ACTIVE_PATTERNS_FILE" || true)
else
  hits="$raw_hits"
fi
set -e

if [ -n "$hits" ]; then
  echo "FAIL: raw LiteRTLM.xcframework references outside the allowlist:" >&2
  echo "$hits" >&2
  ERRORS=$((ERRORS + 1))
else
  echo "  PASS: no raw LiteRTLM.xcframework references outside allowlist"
fi

# =============================================================================
# Layer C: manifest consistency check
# =============================================================================
echo ""
echo "==> Layer C: manifest consistency"

if [ ! -f "$MANIFEST" ]; then
  echo "FAIL: ios/BinaryPods/Frameworks/rewrap-manifest.json not found — run `make sync TAG=<tag>` first" >&2
  ERRORS=$((ERRORS + 1))
else
  # Assert schema_version == 1
  schema_version=$(jq -r .schema_version "$MANIFEST" 2>/dev/null || echo "invalid")
  if [ "$schema_version" != "1" ]; then
    echo "FAIL: manifest schema_version=$schema_version (expected 1)" >&2
    ERRORS=$((ERRORS + 1))
  else
    echo "  schema_version=1 OK"
  fi

  # Assert >=2 xcframework entries
  xcf_count=$(jq '.xcframeworks | length' "$MANIFEST" 2>/dev/null || echo 0)
  if [ "$xcf_count" -lt 2 ]; then
    echo "FAIL: manifest.xcframeworks has $xcf_count entries (expected >=2)" >&2
    ERRORS=$((ERRORS + 1))
  else
    echo "  $xcf_count xcframework entries OK"
  fi

  # Assert each entry's sha256 is 64-hex (guards against placeholder manifest)
  layer_c_ok=true
  while IFS=$'\t' read -r name sha; do
    if ! [[ "$sha" =~ ^[0-9a-f]{64}$ ]]; then
      echo "FAIL: manifest entry '$name' has non-64-hex zip_sha256: '$sha'" >&2
      layer_c_ok=false
    fi
  done < <(jq -r '.xcframeworks[] | [.name, .zip_sha256] | @tsv' "$MANIFEST" 2>/dev/null || true)

  # Assert the rewrapped LiteRTLM entry uses an accepted wrapper name.
  litertlm_name=$(jq -r '.xcframeworks[] | select(.name | test("^(CLiteRTLM|LiteRTLM-rewrapped)\\.xcframework$")) | .name' "$MANIFEST" 2>/dev/null || echo "")
  if [ -z "$litertlm_name" ]; then
    echo "FAIL: no accepted rewrapped LiteRTLM entry in manifest.xcframeworks" >&2
    layer_c_ok=false
  elif ! echo "$litertlm_name" | grep -qE '^(CLiteRTLM|LiteRTLM-rewrapped)\.xcframework$'; then
    echo "FAIL: LiteRTLM manifest entry name '$litertlm_name' is not an accepted rewrapped name" >&2
    layer_c_ok=false
  else
    echo "  Rewrapped LiteRTLM entry OK ($litertlm_name)"
  fi

  # Cross-check binary pod vendored_frameworks resolve to manifest xcframework names.
  set +e
  podspec_xcfws=$(ruby -e "
    require 'json'
    manifest = JSON.parse(File.read('ios/BinaryPods/Frameworks/rewrap-manifest.json'))
    expected = manifest['xcframeworks'].map { |x| \"ios/BinaryPods/Frameworks/#{x['name']}\" }
    puts expected
  " 2>/dev/null)
  set -e

  if [ -n "$podspec_xcfws" ]; then
    while IFS= read -r expected_path; do
      if [ ! -d "$REPO_ROOT/$expected_path" ]; then
        echo "FAIL: manifest xcframework path missing on disk: $expected_path" >&2
        layer_c_ok=false
      fi
    done <<< "$podspec_xcfws"

    if ! grep -q 'Frameworks/CLiteRTLM.xcframework' "$REPO_ROOT/ios/BinaryPods/CLiteRTLMBinary.podspec"; then
      echo "FAIL: CLiteRTLMBinary.podspec does not vendor Frameworks/CLiteRTLM.xcframework" >&2
      layer_c_ok=false
    fi

    if ! grep -q 'Frameworks/GemmaModelConstraintProvider.xcframework' "$REPO_ROOT/ios/BinaryPods/GemmaModelConstraintProviderBinary.podspec"; then
      echo "FAIL: GemmaModelConstraintProviderBinary.podspec does not vendor Frameworks/GemmaModelConstraintProvider.xcframework" >&2
      layer_c_ok=false
    fi

    echo "  Binary pod xcframework paths match manifest OK"
  fi

  if [ "$layer_c_ok" = true ]; then
    echo "  PASS: manifest consistency checks all passed"
  else
    ERRORS=$((ERRORS + 1))
  fi
fi

# =============================================================================
# Layer A: fresh pod install from a temp consumer
# =============================================================================
echo ""
echo "==> Layer A: fresh pod install"

if [ ! -f "$MANIFEST" ]; then
  echo "SKIP: manifest not present — skipping Layer A (run `make sync TAG=<tag>` first)" >&2
  ERRORS=$((ERRORS + 1))
else
  TMPDIR_A=$(mktemp -d)
  trap "rm -rf $TMPDIR_A" EXIT

  # Create a minimal CocoaPods consumer for the two binary pods. We disable user
  # project integration because this layer is checking dependency resolution,
  # binary podspec loading, and generated xcframework support scripts.
  CONSUMER_DIR="$TMPDIR_A/consumer"
  mkdir -p "$CONSUMER_DIR/ios"

  cat > "$CONSUMER_DIR/ios/Podfile" <<PODFILE_EOF
install! 'cocoapods', :integrate_targets => false
platform :ios, '17.0'
use_frameworks!

target 'Consumer' do
  pod 'CLiteRTLMBinary', :path => '${REPO_ROOT}/ios/BinaryPods'
  pod 'GemmaModelConstraintProviderBinary', :path => '${REPO_ROOT}/ios/BinaryPods'
end
PODFILE_EOF

  # Propagate the project's pinned CocoaPods version into the tmpdir so asdf's
  # shim resolves correctly. The tmpdir lives outside the repo, so asdf can't
  # find a parent `.tool-versions` and would otherwise error with
  # "No version is set for command pod". ASDF_COCOAPODS_VERSION wins over
  # `.tool-versions` lookup so we don't have to materialize a file.
  COCOAPODS_VER="$(awk '/^cocoapods /{print $2; exit}' "$REPO_ROOT/.tool-versions" 2>/dev/null || true)"

  cd "$CONSUMER_DIR/ios"
  set +e
  if [ -n "$COCOAPODS_VER" ]; then
    ASDF_COCOAPODS_VERSION="$COCOAPODS_VER" pod install 2>&1
  else
    pod install 2>&1
  fi
  POD_EXIT=$?
  set -e
  cd "$REPO_ROOT"

  if [ "$POD_EXIT" -ne 0 ]; then
    echo "FAIL: pod install exited $POD_EXIT" >&2
    ERRORS=$((ERRORS + 1))
  else
    # Assert Podfile.lock references the rewrapped xcframework name
    PODFILE_LOCK="$CONSUMER_DIR/ios/Podfile.lock"
    if [ ! -f "$PODFILE_LOCK" ]; then
      echo "FAIL: Podfile.lock not generated after pod install" >&2
      ERRORS=$((ERRORS + 1))
    else
      if ! grep -q 'CLiteRTLMBinary' "$PODFILE_LOCK"; then
        echo "FAIL: Podfile.lock does not reference CLiteRTLMBinary" >&2
        echo "  Podfile.lock contents:" >&2
        cat "$PODFILE_LOCK" >&2
        ERRORS=$((ERRORS + 1))
      else
        echo "  PASS: Podfile.lock references CLiteRTLMBinary"
      fi

      if ! grep -q 'GemmaModelConstraintProviderBinary' "$PODFILE_LOCK"; then
        echo "FAIL: Podfile.lock does not reference GemmaModelConstraintProviderBinary" >&2
        echo "  Podfile.lock contents:" >&2
        cat "$PODFILE_LOCK" >&2
        ERRORS=$((ERRORS + 1))
      else
        echo "  PASS: Podfile.lock references GemmaModelConstraintProviderBinary"
      fi

      support_dir="$CONSUMER_DIR/ios/Pods/Target Support Files/CLiteRTLMBinary"
      if ! grep -q 'CLiteRTLM.xcframework' "$support_dir/CLiteRTLMBinary-xcframeworks.sh"; then
        echo "FAIL: CocoaPods support script does not reference CLiteRTLM.xcframework" >&2
        ERRORS=$((ERRORS + 1))
      else
        echo "  PASS: CocoaPods generated CLiteRTLM xcframework support script"
      fi

      # Assert NO MediaPipeTasksGenAI in the binary pod install.
      if grep -q 'MediaPipeTasksGenAI' "$PODFILE_LOCK"; then
        echo "FAIL: Podfile.lock contains MediaPipeTasksGenAI (should only appear in MediaPipeFallback subspec)" >&2
        ERRORS=$((ERRORS + 1))
      else
        echo "  PASS: MediaPipeTasksGenAI absent from binary pod install"
      fi
    fi
  fi
fi

# =============================================================================
# Final result
# =============================================================================
echo ""
if [ "$ERRORS" -eq 0 ]; then
  echo "==> ALL LAYERS PASSED (A + B + C)"
  exit 0
else
  echo "==> FAILED: $ERRORS layer(s) failed" >&2
  exit 1
fi
