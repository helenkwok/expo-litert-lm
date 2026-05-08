require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

Pod::Spec.new do |s|
  s.name             = "ExpoLitertLm"
  s.version          = package["version"]
  s.summary          = package["description"]
  s.description      = package["description"]
  s.license          = package["license"] || "Proprietary"
  s.author           = package["author"] || "Helen Kwok"
  s.homepage         = "https://github.com/google-ai-edge/mediapipe"
  s.platforms        = {
    :ios => "17.0",
    :tvos => "17.0"
  }
  s.swift_version    = "5.9"
  s.source           = { :path => "." }
  s.static_framework = true

  s.dependency "ExpoModulesCore"
  s.dependency "MediaPipeTasksGenAI"
  s.dependency "MediaPipeTasksGenAIC"

  s.source_files = "ios/**/*.{h,m,mm,swift}"
  s.pod_target_xcconfig = {
    "DEFINES_MODULE" => "YES",
    "SWIFT_COMPILATION_MODE" => "wholemodule"
  }

  install_modules_dependencies(s)
end
