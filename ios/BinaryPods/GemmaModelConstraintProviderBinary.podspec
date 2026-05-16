require "json"

# =============================================================================
# GemmaModelConstraintProviderBinary.podspec — top-level binary pod
# =============================================================================
# Phase 14-09 Task 2 (split-binary architectural fix). Reason:
# CocoaPods #11948 silently drops vendored_frameworks declared on a subspec
# under static linkage. Moving vendored_frameworks to a top-level Pod::Spec.new
# bypasses that defect.
#
# Discovered by consumers via the expo-litert-lm config plugin
# (plugin/withLitertLmBinaryPods.ts), which injects
#   pod 'GemmaModelConstraintProviderBinary', :path => '../node_modules/expo-litert-lm/ios'
# into the host Podfile.
#
# Version is read from Frameworks/rewrap-manifest.json — same source of truth
# as ExpoLitertLm.podspec.
# =============================================================================

manifest_path = File.expand_path("Frameworks/rewrap-manifest.json", __dir__)
manifest_version = "0.0.0-manifest-missing"

begin
  raise "rewrap-manifest.json missing at #{manifest_path}" unless File.exist?(manifest_path)
  manifest = JSON.parse(File.read(manifest_path))
  upstream = manifest["upstream_version"].to_s.sub(/^v/, "")
  iter     = manifest["rewrap_iteration"].to_s
  manifest_version = "#{upstream}.rewrap.#{iter}"
rescue => e
  warn "[GemmaModelConstraintProviderBinary] WARNING: could not read rewrap-manifest.json — #{e.message}"
end

Pod::Spec.new do |s|
  s.name             = "GemmaModelConstraintProviderBinary"
  s.version          = manifest_version
  s.summary          = "Binary pod for GemmaModelConstraintProvider.xcframework."
  s.description      = "Top-level vendored_frameworks pod for GemmaModelConstraintProvider. Split out from ExpoLitertLm/Core to work around CocoaPods #11948."
  s.homepage         = "https://github.com/helenkwok/expo-litert-lm"
  s.license          = { :type => "MIT" }
  s.author           = "Helen Kwok"
  s.platforms        = { :ios => "17.0", :tvos => "17.0" }
  s.source           = { :path => "." }
  s.swift_version    = "5.9"

  s.vendored_frameworks = "Frameworks/GemmaModelConstraintProvider.xcframework"

  s.pod_target_xcconfig = {
    "LD_RUNPATH_SEARCH_PATHS" => "$(inherited) @executable_path/Frameworks @loader_path/Frameworks"
  }
end
