require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

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

    c.vendored_frameworks = [
      "ios/Frameworks/CLiteRTLM.xcframework",
      "ios/Frameworks/GemmaModelConstraintProvider.xcframework"
    ]

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
