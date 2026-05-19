/**
 * expo-litert-lm config plugin
 *
 * Phase 14-09 Task 2: injects top-level binary pod entries into the consumer's
 * ios/Podfile so CocoaPods discovers CLiteRTLMBinary.podspec — which lives
 * alongside ExpoLitertLm.podspec under ios/ but is NOT auto-discovered by Expo
 * autolinking (autolinking only picks the podName from expo-module.config.json).
 *
 * Why we need this:
 *   CocoaPods #11948 silently drops vendored_frameworks declared on a SUBSPEC
 *   under static linkage. Moving the xcframework onto a top-level Pod::Spec.new
 *   bypasses that defect. The pod entry here is how that top-level spec gets
 *   loaded.
 *
 * v0.12.0 spike (feat/litert-v0.12): GemmaModelConstraintProviderBinary dropped
 * — GMCP symbols are now statically linked into Google's first-party
 * CLiteRTLM.framework (single xcframework, single pod entry).
 */

const { withDangerousMod, createRunOncePlugin } = require("@expo/config-plugins");
const fs = require("node:fs");
const path = require("node:path");

const PKG = require("./package.json");

const MARKER_BEGIN = "# >>> expo-litert-lm binary pods (managed by app.plugin.js) >>>";
const MARKER_END   = "# <<< expo-litert-lm binary pods (managed by app.plugin.js) <<<";

function podBlock(modulePath) {
  return [
    MARKER_BEGIN,
    `  pod 'CLiteRTLMBinary', :path => '${modulePath}'`,
    MARKER_END,
  ].join("\n");
}

function injectIntoPodfile(podfile, modulePath) {
  // Idempotent: strip any previous managed block first, then re-inject.
  const stripped = podfile.replace(
    new RegExp(`${MARKER_BEGIN}[\\s\\S]*?${MARKER_END}\\n?`, "g"),
    "",
  );

  // Inject inside `target 'X' do ... end`. Match the first top-level target.
  const targetRegex = /(target\s+'[^']+'\s+do\b)/;
  if (!targetRegex.test(stripped)) {
    throw new Error(
      "expo-litert-lm plugin: no `target ... do` block found in Podfile",
    );
  }
  return stripped.replace(
    targetRegex,
    `$1\n${podBlock(modulePath)}`,
  );
}

function withLitertLmBinaryPods(config) {
  return withDangerousMod(config, [
    "ios",
    async (modConfig) => {
      const podfilePath = path.join(
        modConfig.modRequest.platformProjectRoot,
        "Podfile",
      );
      if (!fs.existsSync(podfilePath)) {
        throw new Error(
          `expo-litert-lm plugin: Podfile not found at ${podfilePath}`,
        );
      }

      // Relative path from ios/ (where Podfile lives) to the module's ios/ dir.
      // node_modules/expo-litert-lm/ios is the canonical location.
      const modulePath = "../node_modules/expo-litert-lm/ios/BinaryPods";

      const before = fs.readFileSync(podfilePath, "utf8");
      const after  = injectIntoPodfile(before, modulePath);
      if (after !== before) {
        fs.writeFileSync(podfilePath, after, "utf8");
      }
      return modConfig;
    },
  ]);
}

module.exports = createRunOncePlugin(
  withLitertLmBinaryPods,
  PKG.name,
  PKG.version,
);
