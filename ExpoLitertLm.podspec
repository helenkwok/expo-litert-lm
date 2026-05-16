require "json"

# =============================================================================
# ExpoLitertLm.podspec — manifest-driven xcframework consumer
# =============================================================================
# ios/Frameworks/rewrap-manifest.json is the single source of truth for
# the xcframework names, versions, and sha256 values. It is populated by
# scripts/sync-litertlm-swift.sh (Phase 14 D-31, D-34).
#
# If the manifest is missing, pod install will fail with a clear message.
# Run `make sync TAG=v<upstream>+rewrap.<n>` first.
# =============================================================================

# Layer C assertion: read the manifest and validate invariants at install time.
begin
  manifest_path = File.expand_path("ios/Frameworks/rewrap-manifest.json", __dir__)
  raise "rewrap-manifest.json missing at #{manifest_path} — run `make sync TAG=v<upstream>+rewrap.<n>` first (Phase 14 D-34)" unless File.exist?(manifest_path)

  rewrap_manifest = JSON.parse(File.read(manifest_path))
  raise "unexpected manifest schema_version=#{rewrap_manifest['schema_version']} (expected 1)" unless rewrap_manifest["schema_version"] == 1

  xcfws = rewrap_manifest["xcframeworks"] || []
  raise "manifest.xcframeworks must have >=2 entries, got #{xcfws.length} — re-run `make sync TAG=...`" unless xcfws.length >= 2

  # Layer C assertion #1: the LiteRTLM xcframework MUST carry the '-rewrapped' qualifier.
  # A future upstream slip-up (raw LiteRTLM.xcframework vendored without rewrap) will
  # fail pod install loudly here rather than crashing silently at runtime.
  litertlm_entry = xcfws.find { |x| x["name"].to_s.start_with?("LiteRTLM") }
  raise "manifest has no LiteRTLM xcframework entry" unless litertlm_entry
  raise "LiteRTLM entry name (#{litertlm_entry['name']}) must contain '-rewrapped' (raw upstream xcframework is not accepted)" unless litertlm_entry["name"].include?("-rewrapped")

  # Layer C assertion #2: every entry must have a non-empty 64-hex sha256.
  xcfws.each do |x|
    sha = x["zip_sha256"].to_s
    raise "xcframework #{x['name']} has missing/invalid zip_sha256 (#{sha.inspect}) — re-run `make sync TAG=...`" unless sha.match?(/\A[0-9a-f]{64}\z/)
  end

  # Build vendored_frameworks array: ios/Frameworks/<name> for each entry
  VENDORED_XCFRAMEWORKS = xcfws.map { |x| "ios/Frameworks/#{x['name']}" }.freeze

  # Derive version from manifest: <upstream_ver_without_v>.rewrap.<iteration>
  upstream_ver = rewrap_manifest["upstream_version"].to_s.sub(/^v/, "")
  rewrap_iter  = rewrap_manifest["rewrap_iteration"].to_s
  MANIFEST_VERSION = "#{upstream_ver}.rewrap.#{rewrap_iter}".freeze

rescue => e
  # Provide an informative failure rather than a Ruby NoMethodError deep in the stack.
  # pod lib lint will see this; `pod install` will also fail with a clear message.
  warn "[ExpoLitertLm] WARNING: could not read rewrap-manifest.json — #{e.message}"
  VENDORED_XCFRAMEWORKS = [
    "ios/Frameworks/LiteRTLM-rewrapped.xcframework",
    "ios/Frameworks/GemmaModelConstraintProvider.xcframework",
  ].freeze
  MANIFEST_VERSION = "0.0.0-manifest-missing".freeze
end

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

Pod::Spec.new do |s|
  s.name             = "ExpoLitertLm"
  # Version derived from manifest (single SoT). Falls back to package.json version
  # if manifest is not yet synced (e.g. pod lib lint on a fresh checkout).
  s.version          = MANIFEST_VERSION == "0.0.0-manifest-missing" ? package["version"] : MANIFEST_VERSION
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

    c.source_files  = "ios/**/*.{h,m,mm,swift}"
    # CRITICAL: keep MediaPipeFallback sources out of the default compile —
    # otherwise the opt-in MediaPipe imports fail to resolve under default
    # install (RESEARCH.md Q8). 14-03 lands the actual fallback bridge under
    # ios/MediaPipeFallback/.
    c.exclude_files = "ios/MediaPipeFallback/**/*"

    # vendored_frameworks is manifest-driven (BOTH LiteRTLM-rewrapped + GemmaModelConstraintProvider).
    # The array is populated from ios/Frameworks/rewrap-manifest.json at pod install time.
    # Populated by: make sync TAG=v<upstream>+rewrap.<n>
    c.vendored_frameworks = VENDORED_XCFRAMEWORKS

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

    m.source_files = "ios/MediaPipeFallback/**/*.{h,m,mm,swift}"

    m.pod_target_xcconfig = {
      "OTHER_SWIFT_FLAGS" => "$(inherited) -D EXPO_LITERTLM_MEDIAPIPE_FALLBACK"
    }
  end

  install_modules_dependencies(s)
end
