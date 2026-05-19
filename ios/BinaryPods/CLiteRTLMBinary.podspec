require "json"

# =============================================================================
# CLiteRTLMBinary.podspec — top-level binary pod for CLiteRTLM.xcframework
# =============================================================================
# Phase 14-09 Task 2 (split-binary architectural fix). Reason:
# CocoaPods #11948 silently drops vendored_frameworks declared on a subspec
# under static linkage. Moving vendored_frameworks to a top-level Pod::Spec.new
# bypasses that defect.
#
# v0.12.0 spike (feat/litert-v0.12): xcframework is now Google's first-party
# CLiteRTLM.xcframework from google-ai-edge/LiteRT-LM v0.12.0 release. Single
# 39 MB binary with Metal accelerator + TopK sampler + GemmaModelConstraint-
# Provider statically linked (no separate xcframeworks needed). The rewrap
# manifest is retired — Google's binary already ships with proper
# CFBundleShortVersionString and CFBundleVersion.
#
# Version is read from package.json since the upstream is a first-party
# Google release; tracking is via the upstream LiteRT-LM release tag (v0.12.0).
# =============================================================================

package = JSON.parse(File.read(File.join(__dir__, "..", "..", "package.json")))

# Upstream LiteRT-LM release we ship. Update in lockstep with
# Frameworks/CLiteRTLM.xcframework. See README for SHA verification.
LITERT_LM_UPSTREAM = "0.12.0"

Pod::Spec.new do |s|
  s.name             = "CLiteRTLMBinary"
  s.version          = package["version"]
  s.summary          = "Binary pod for CLiteRTLM.xcframework (LiteRT-LM v#{LITERT_LM_UPSTREAM} first-party)."
  s.description      = "Top-level vendored_frameworks pod for CLiteRTLM. Split out from ExpoLitertLm/Core to work around CocoaPods #11948. Ships google-ai-edge/LiteRT-LM v#{LITERT_LM_UPSTREAM} xcframework."
  s.homepage         = "https://github.com/helenkwok/expo-litert-lm"
  s.license          = { :type => "MIT" }
  s.author           = "Helen Kwok"
  s.platforms        = { :ios => "17.0", :tvos => "17.0" }
  s.source           = { :path => "." }
  s.swift_version    = "5.9"

  s.vendored_frameworks = "Frameworks/CLiteRTLM.xcframework"

  s.pod_target_xcconfig = {
    "LD_RUNPATH_SEARCH_PATHS" => "$(inherited) @executable_path/Frameworks @loader_path/Frameworks"
  }
end
