require "json"

# =============================================================================
# ExpoLitertLm.podspec
# =============================================================================
# v0.12.0 spike (feat/litert-v0.12): xcframework is now Google's first-party
# CLiteRTLM.xcframework from google-ai-edge/LiteRT-LM v0.12.0 release. Single
# 39 MB binary with Metal accelerator + TopK sampler + GemmaModelConstraint-
# Provider statically linked. Rewrap manifest retired (Google's binary is
# already properly versioned: CFBundleShortVersionString=1.0, CFBundleVersion=1).
#
# Phase 14-07: podspec relocated from package root to ios/ to satisfy Expo SDK
# 55's autolinking convention. Without this, vendored_frameworks were silently
# dropped from the Pods integration.
# Phase 14-09: vendored_frameworks moved to a top-level binary pod
# (CLiteRTLMBinary) to work around CocoaPods #11948 silent-drop under static
# linkage. This podspec depends on CLiteRTLMBinary; the binary pod is injected
# into the host Podfile by plugin/withLitertLmBinaryPods.ts.
# =============================================================================

# package.json sits at the package root, i.e. one level up from this podspec.
package = JSON.parse(File.read(File.join(__dir__, "..", "package.json")))

# Upstream LiteRT-LM release we ship. Bumped in lockstep with
# BinaryPods/Frameworks/CLiteRTLM.xcframework.
LITERT_LM_UPSTREAM = "0.12.0"

Pod::Spec.new do |s|
  s.name             = "ExpoLitertLm"
  s.version          = package["version"]
  s.summary          = package["description"]
  s.description      = package["description"]
  s.license          = package["license"] || "MIT"
  s.author           = package["author"] || "Helen Kwok"
  s.homepage         = "https://github.com/helenkwok/expo-litert-lm"
  s.platforms        = {
    :ios => "17.0",
    :tvos => "17.0"
  }
  s.swift_version    = "5.9"
  s.source           = { :path => "." }

  # vendored CLiteRTLM.xcframework embeds the LiteRT-LM C dylib. CocoaPods
  # #11948 — declaring this spec static_framework while it contains dylibs
  # crashes the host app at launch under @rpath resolution.
  s.cocoapods_version = ">= 1.10.0"   # xcframework support floor

  s.default_subspecs = "Core"

  s.subspec "Core" do |c|
    c.dependency "ExpoModulesCore"

    # Phase 14-09 Task 2: xcframework moved to top-level binary pod to work
    # around CocoaPods #11948 (vendored_frameworks on a subspec silently
    # dropped under static linkage). Injected into host Podfile via
    # plugin/withLitertLmBinaryPods.ts (and app.plugin.js).
    #
    # v0.12.0: GemmaModelConstraintProviderBinary dropped — GMCP symbols are
    # now statically linked into CLiteRTLM.framework (see otool dump in
    # .planning/notes/2026-05-19-litert-lm-v0.12-impact.md).
    c.dependency "CLiteRTLMBinary"

    # Source files glob: this podspec sits in ios/, so "**/*.{h,m,mm,swift}"
    # matches everything under ios/ — including Sources/LiteRTLM/ vendored
    # first-party Swift sources from google-ai-edge/LiteRT-LM@v#{LITERT_LM_UPSTREAM}.
    c.source_files  = "**/*.{h,m,mm,swift}"
    # Exclusions (relative to ios/):
    #  - MediaPipeFallback/**: opt-in subspec sources kept out of default compile.
    #  - BinaryPods/**: prevents the source_files glob from scooping up C
    #    headers inside the vendored xcframework (CLiteRTLM.framework ships
    #    engine.h + capabilities_c.h + CLiteRTLM.h in its Headers/ dir).
    c.exclude_files = ["MediaPipeFallback/**/*", "BinaryPods/**/*"]

    c.pod_target_xcconfig = {
      "DEFINES_MODULE"            => "YES",
      "SWIFT_COMPILATION_MODE"    => "wholemodule",
      "LD_RUNPATH_SEARCH_PATHS"   => "$(inherited) @executable_path/Frameworks @loader_path/Frameworks"
    }
  end

  s.subspec "MediaPipeFallback" do |m|
    # Opt-in only — consumers add:
    #   pod 'ExpoLitertLm', :subspecs => ['Core', 'MediaPipeFallback']
    # in their Podfile. Default install ships first-party LiteRT-LM only.
    m.dependency "MediaPipeTasksGenAI"
    m.dependency "MediaPipeTasksGenAIC"

    m.source_files = "MediaPipeFallback/**/*.{h,m,mm,swift}"

    m.pod_target_xcconfig = {
      "OTHER_SWIFT_FLAGS" => "$(inherited) -D EXPO_LITERTLM_MEDIAPIPE_FALLBACK"
    }
  end

  install_modules_dependencies(s)
end
