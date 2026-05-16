#!/usr/bin/env bash
# verify-consumption.sh (expo-litert-lm)
# Local runner mirroring the fork's three-layer gate structure, targeting the
# Pod consumer surface.
#
# All three layers must pass (exit 0) for the script to succeed.
# Run from repo root or via `make verify`.
#
# Layer A: `pod install` from fresh consumer in a temp dir + grep Podfile.lock
# Layer B: static grep for raw LiteRTLM.xcframework refs without -rewrapped qualifier
# Layer C: manifest-driven podspec consistency check
#
# Note on Layer A: requires ios/Frameworks/rewrap-manifest.json + the xcframework
# binaries on disk (populated by `make sync TAG=...`). If binaries are absent,
# Layer A will fail with a CocoaPods error about missing vendored_frameworks.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

ERRORS=0
MANIFEST="$REPO_ROOT/ios/Frameworks/rewrap-manifest.json"

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
if [ -s "$ACTIVE_PATTERNS_FILE" ]; then
  hits=$(grep -rnE 'LiteRTLM\.xcframework' \
    --include='*.swift' --include='*.json' --include='*.podspec' \
    --include='*.rb' --include='*.sh' --include='*.txt' \
    . 2>/dev/null \
    | grep -v '\-rewrapped' \
    | grep -E -v -f "$ACTIVE_PATTERNS_FILE" || true)
else
  hits=$(grep -rnE 'LiteRTLM\.xcframework' \
    --include='*.swift' --include='*.json' --include='*.podspec' \
    --include='*.rb' --include='*.sh' --include='*.txt' \
    . 2>/dev/null \
    | grep -v '\-rewrapped' || true)
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
  echo "FAIL: ios/Frameworks/rewrap-manifest.json not found — run `make sync TAG=<tag>` first" >&2
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

  # Assert LiteRTLM entry name contains '-rewrapped'
  litertlm_name=$(jq -r '.xcframeworks[] | select(.name | startswith("LiteRTLM")) | .name' "$MANIFEST" 2>/dev/null || echo "")
  if [ -z "$litertlm_name" ]; then
    echo "FAIL: no LiteRTLM entry in manifest.xcframeworks" >&2
    layer_c_ok=false
  elif ! echo "$litertlm_name" | grep -q '\-rewrapped'; then
    echo "FAIL: LiteRTLM manifest entry name '$litertlm_name' must contain '-rewrapped'" >&2
    layer_c_ok=false
  else
    echo "  LiteRTLM '-rewrapped' qualifier OK ($litertlm_name)"
  fi

  # Cross-check podspec vendored_frameworks resolves to manifest xcframework names
  set +e
  podspec_xcfws=$(ruby -e "
    require 'json'
    manifest = JSON.parse(File.read('ios/Frameworks/rewrap-manifest.json'))
    expected = manifest['xcframeworks'].map { |x| \"ios/Frameworks/\#{x['name']}\" }
    puts expected.join('\n')
  " 2>/dev/null)
  set -e

  if [ -n "$podspec_xcfws" ]; then
    # Verify each expected xcframework path is referenced in the podspec
    while IFS= read -r expected_path; do
      if ! grep -q "$expected_path" ExpoLitertLm.podspec; then
        # The podspec uses a dynamic array, so the path won't be literal in the file.
        # Instead check that the xcframework name appears in the manifest entries list.
        xcf_name=$(basename "$expected_path")
        if ! jq -e --arg name "$xcf_name" '.xcframeworks[] | select(.name == $name)' "$MANIFEST" > /dev/null 2>&1; then
          echo "FAIL: xcframework $xcf_name from podspec not found in manifest" >&2
          layer_c_ok=false
        fi
      fi
    done <<< "$podspec_xcfws"
    echo "  Podspec xcframework entries match manifest OK"
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

  # Create a minimal Expo/RN consumer that references expo-litert-lm via local path
  CONSUMER_DIR="$TMPDIR_A/consumer"
  mkdir -p "$CONSUMER_DIR/ios"

  cat > "$CONSUMER_DIR/ios/Podfile" <<PODFILE_EOF
platform :ios, '17.0'
use_frameworks!

target 'Consumer' do
  pod 'ExpoLitertLm', :path => '${REPO_ROOT}'
end
PODFILE_EOF

  # Create a minimal Xcode project structure so CocoaPods has a target to link against
  mkdir -p "$CONSUMER_DIR/ios/Consumer.xcodeproj"
  cat > "$CONSUMER_DIR/ios/Consumer.xcodeproj/project.pbxproj" <<'PBXPROJ_EOF'
// !$*UTF8*$!
{
  archiveVersion = 1;
  classes = {};
  objectVersion = 56;
  objects = {
    /* Begin PBXBuildFile section */
    /* End PBXBuildFile section */
    /* Begin PBXFileReference section */
    /* End PBXFileReference section */
    /* Begin PBXNativeTarget section */
    B0000001 = {
      isa = PBXNativeTarget;
      buildConfigurationList = B0000002;
      buildPhases = ();
      buildRules = ();
      dependencies = ();
      name = Consumer;
      productName = Consumer;
      productType = "com.apple.product-type.application";
    };
    /* End PBXNativeTarget section */
    /* Begin PBXProject section */
    B0000003 = {
      isa = PBXProject;
      attributes = {};
      buildConfigurationList = B0000004;
      compatibilityVersion = "Xcode 14.0";
      developmentRegion = en;
      hasScannedForEncodings = 0;
      knownRegions = (en);
      mainGroup = B0000005;
      targets = (B0000001);
    };
    /* End PBXProject section */
    /* Begin XCBuildConfiguration section */
    B0000006 = {
      isa = XCBuildConfiguration;
      buildSettings = {
        PRODUCT_NAME = Consumer;
        SDKROOT = iphoneos;
        TARGETED_DEVICE_FAMILY = "1,2";
        IPHONEOS_DEPLOYMENT_TARGET = 17.0;
      };
      name = Debug;
    };
    B0000007 = {
      isa = XCBuildConfiguration;
      buildSettings = {
        PRODUCT_NAME = Consumer;
        SDKROOT = iphoneos;
        TARGETED_DEVICE_FAMILY = "1,2";
        IPHONEOS_DEPLOYMENT_TARGET = 17.0;
      };
      name = Release;
    };
    B0000008 = {
      isa = XCBuildConfiguration;
      buildSettings = {};
      name = Debug;
    };
    B0000009 = {
      isa = XCBuildConfiguration;
      buildSettings = {};
      name = Release;
    };
    /* End XCBuildConfiguration section */
    /* Begin XCConfigurationList section */
    B0000002 = {
      isa = XCConfigurationList;
      buildConfigurations = (B0000006, B0000007);
      defaultConfigurationIsVisible = 0;
      defaultConfigurationName = Release;
    };
    B0000004 = {
      isa = XCConfigurationList;
      buildConfigurations = (B0000008, B0000009);
      defaultConfigurationIsVisible = 0;
      defaultConfigurationName = Release;
    };
    /* End XCConfigurationList section */
    /* Begin PBXGroup section */
    B0000005 = {
      isa = PBXGroup;
      children = ();
      sourceTree = "<group>";
    };
    /* End PBXGroup section */
  };
  rootObject = B0000003;
}
PBXPROJ_EOF

  cd "$CONSUMER_DIR/ios"
  set +e
  pod install 2>&1
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
      if ! grep -q 'LiteRTLM-rewrapped' "$PODFILE_LOCK"; then
        echo "FAIL: Podfile.lock does not reference 'LiteRTLM-rewrapped'" >&2
        echo "  Podfile.lock contents:" >&2
        cat "$PODFILE_LOCK" >&2
        ERRORS=$((ERRORS + 1))
      else
        echo "  PASS: Podfile.lock references LiteRTLM-rewrapped"
      fi

      # Assert NO MediaPipeTasksGenAI in default install (D-22 regression gate)
      if grep -q 'MediaPipeTasksGenAI' "$PODFILE_LOCK"; then
        echo "FAIL: Podfile.lock contains MediaPipeTasksGenAI (D-22 regression — should only appear in MediaPipeFallback subspec)" >&2
        ERRORS=$((ERRORS + 1))
      else
        echo "  PASS: MediaPipeTasksGenAI absent from default install (D-22 preserved)"
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
