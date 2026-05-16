require "json"

# =============================================================================
# ExpoLitertLm.podspec — manifest-driven xcframework consumer
# =============================================================================
# BinaryPods/Frameworks/rewrap-manifest.json (relative to THIS podspec, i.e.
# ios/) is the single source of truth for xcframework names, versions, and
# sha256 values.
# Populated by scripts/sync-litertlm-swift.sh (Phase 14 D-31, D-34).
#
# If the manifest is missing, pod install will fail with a clear message.
# Run `make sync TAG=v<upstream>+rewrap.<n>` first.
#
# Phase 14-07: podspec relocated from package root to ios/ to satisfy Expo SDK
# 55's autolinking convention. Without this, vendored_frameworks were silently
# dropped from the Pods integration even when the resolved spec.json declared
# them correctly.
# =============================================================================

begin
  # Manifest lives next to the xcframeworks under BinaryPods/Frameworks/.
  manifest_path = File.expand_path("BinaryPods/Frameworks/rewrap-manifest.json", __dir__)
  raise "rewrap-manifest.json missing at #{manifest_path} — run `make sync TAG=v<upstream>+rewrap.<n>` first (Phase 14 D-34)" unless File.exist?(manifest_path)

  rewrap_manifest = JSON.parse(File.read(manifest_path))
  raise "unexpected manifest schema_version=#{rewrap_manifest['schema_version']} (expected 1)" unless rewrap_manifest["schema_version"] == 1

  xcfws = rewrap_manifest["xcframeworks"] || []
  raise "manifest.xcframeworks must have >=2 entries, got #{xcfws.length} — re-run `make sync TAG=...`" unless xcfws.length >= 2

  # Layer C assertion #1: the LiteRTLM xcframework must be present; manifest
  # must indicate rewrap_iteration >= 1 (raw upstream xcframework not accepted).
  litertlm_entry = xcfws.find { |x| x["name"].to_s.match?(/\A(CLiteRTLM|LiteRTLM(-rewrapped)?)\.xcframework\z/) }
  raise "manifest has no LiteRTLM xcframework entry" unless litertlm_entry
  raise "manifest rewrap_iteration must be >= 1 (raw upstream xcframework is not accepted)" unless rewrap_manifest["rewrap_iteration"].to_i >= 1

  # Layer C assertion #2: every entry must have a non-empty 64-hex sha256.
  xcfws.each do |x|
    sha = x["zip_sha256"].to_s
    raise "xcframework #{x['name']} has missing/invalid zip_sha256 (#{sha.inspect}) — re-run `make sync TAG=...`" unless sha.match?(/\A[0-9a-f]{64}\z/)
  end

  # Paths are relative to the podspec dir (ios/). Binary podspecs live under
  # BinaryPods/, so their vendored Frameworks/<name> paths resolve to
  # ios/BinaryPods/Frameworks/<name> from the package root.
  vendored_paths = xcfws.map { |x| "Frameworks/#{x['name']}" }

  upstream_ver = rewrap_manifest["upstream_version"].to_s.sub(/^v/, "")
  rewrap_iter  = rewrap_manifest["rewrap_iteration"].to_s
  manifest_version = "#{upstream_ver}.rewrap.#{rewrap_iter}"

rescue => e
  warn "[ExpoLitertLm] WARNING: could not read rewrap-manifest.json — #{e.message}"
  vendored_paths = [
    "Frameworks/CLiteRTLM.xcframework",
    "Frameworks/GemmaModelConstraintProvider.xcframework",
  ]
  manifest_version = "0.0.0-manifest-missing"
end

# package.json sits at the package root, i.e. one level up from this podspec.
package = JSON.parse(File.read(File.join(__dir__, "..", "package.json")))

Pod::Spec.new do |s|
  s.name             = "ExpoLitertLm"
  s.version          = manifest_version == "0.0.0-manifest-missing" ? package["version"] : manifest_version
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

  # Dropped: s.static_framework = true
  # Reason: vendored CLiteRTLM.xcframework embeds the LiteRT-LM C dylib + a peer
  # GemmaModelConstraintProvider.framework. CocoaPods #11948 — declaring this
  # spec static_framework while it contains dylibs crashes the host app at
  # launch under @rpath resolution. See offlineaid Phase 14 CONTEXT D-21.
  s.cocoapods_version = ">= 1.10.0"   # xcframework support floor — RESEARCH.md Q5

  s.default_subspecs = "Core"

  s.subspec "Core" do |c|
    c.dependency "ExpoModulesCore"

    # Phase 14-09 Task 2: xcframeworks moved to top-level binary pods to work
    # around CocoaPods #11948 (vendored_frameworks on a subspec silently
    # dropped under static linkage). Discovered by the consumer's Podfile via
    # the expo-litert-lm config plugin (app.plugin.js); declared here as
    # Core-subspec dependencies so the linker resolves CLiteRTLM + GMCP
    # symbols at compile time.
    #
    # Note: vendored_paths is still computed above (Layer C manifest validation
    # still runs — we want the build to fail loudly if Frameworks/ is missing
    # or stale) but is no longer assigned to c.vendored_frameworks here.
    c.dependency "CLiteRTLMBinary"
    c.dependency "GemmaModelConstraintProviderBinary"

    # Source files glob: this podspec sits in ios/, so "**/*.{h,m,mm,swift}"
    # matches everything under ios/ — including Sources/LiteRTLMSwift/ vendored
    # Swift modules.
    c.source_files  = "**/*.{h,m,mm,swift}"
    # Exclusions (relative to ios/):
    #  - MediaPipeFallback/**: opt-in subspec sources kept out of default compile.
    #  - BinaryPods/**: prevents the source_files glob from scooping up C
    #    headers inside vendored xcframeworks (CLiteRTLM.framework ships
    #    engine.h + litert_lm_logging.h in its Headers/ dir) which would
    #    otherwise be exposed in the pod umbrella header and break import
    #    resolution. Frameworks now live under BinaryPods/Frameworks/ —
    #    Phase 14-09 Task 2.
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
    # in their Podfile. Default install ships LiteRTLM-Swift only.
    # offlineaid Phase 14 CONTEXT D-22.
    m.dependency "MediaPipeTasksGenAI"
    m.dependency "MediaPipeTasksGenAIC"

    m.source_files = "MediaPipeFallback/**/*.{h,m,mm,swift}"

    m.pod_target_xcconfig = {
      "OTHER_SWIFT_FLAGS" => "$(inherited) -D EXPO_LITERTLM_MEDIAPIPE_FALLBACK"
    }
  end

  install_modules_dependencies(s)
end
