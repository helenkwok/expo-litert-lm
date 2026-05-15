#if EXPO_LITERTLM_MEDIAPIPE_FALLBACK
import Foundation
import MediaPipeTasksGenai

// Opt-in MediaPipe Tasks GenAI path for `.task` model files. Compiled only when
// the `MediaPipeFallback` subspec is added to the consumer Podfile per
// offlineaid Phase 14 CONTEXT D-22 / D-23. Behaviour mirrors the pre-rewrite
// (v0.1.x) module byte-for-byte so emergency RCs preserve the legacy code path
// without surprises.

struct MediaPipeLoadConfig: Equatable {
  let maxTokens: Int
  let modelPath: String
  let preferredBackend: String
  let temperature: Double
  let topK: Int
}

final class MediaPipeFallbackEngine {
  private var llmInference: LlmInference?
  private(set) var loadedConfig: MediaPipeLoadConfig?

  func load(
    modelPath: String,
    maxTokens: Int,
    topK: Int,
    temperature: Double,
    preferredBackend: String
  ) throws {
    let options = LlmInferenceOptions()
    options.baseOptions.modelPath = modelPath
    options.maxTokens = maxTokens
    options.topk = topK
    options.temperature = Float(temperature)
    options.randomSeed = Int.random(in: 1...Int(Int32.max))

    llmInference = try LlmInference(options: options)
    loadedConfig = MediaPipeLoadConfig(
      maxTokens: maxTokens,
      modelPath: modelPath,
      preferredBackend: preferredBackend,
      temperature: temperature,
      topK: topK
    )
  }

  func unload() {
    llmInference = nil
    loadedConfig = nil
  }

  /// Stream tokens from MediaPipe. `isActive` is the parent module's UUID gate
  /// — return false to short-circuit emission; the parent retains cancellation
  /// authority. `emit` runs on @MainActor inside the parent.
  func generate(
    prompt: String,
    isActive: @escaping () -> Bool,
    emit: @escaping (_ text: String, _ delta: String, _ done: Bool) async -> Void
  ) async throws -> String {
    guard let llmInference else {
      throw NSError(
        domain: "ExpoLitertLm.MediaPipeFallback",
        code: -1,
        userInfo: [NSLocalizedDescriptionKey: "MediaPipeFallback engine not loaded."]
      )
    }

    var latestText = ""
    let resultStream = llmInference.generateResponseAsync(inputText: prompt)
    for try await partial in resultStream {
      if !isActive() {
        throw NSError(
          domain: "ExpoLitertLm.MediaPipeFallback",
          code: -2,
          userInfo: [NSLocalizedDescriptionKey: "LiteRT generation was cancelled."]
        )
      }

      let progress = Self.normalizeProgress(latestText: latestText, partial: partial)
      latestText = progress.text

      if !progress.delta.isEmpty {
        await emit(latestText, progress.delta, false)
      }
    }

    if !isActive() {
      throw NSError(
        domain: "ExpoLitertLm.MediaPipeFallback",
        code: -2,
        userInfo: [NSLocalizedDescriptionKey: "LiteRT generation was cancelled."]
      )
    }

    await emit(latestText, "", true)
    return latestText
  }

  // Cumulative-text delta normaliser — preserved verbatim from the pre-rewrite
  // module. MediaPipe emits cumulative `partial` strings; LiteRTLM-Swift emits
  // delta chunks already (no normaliser needed on that path).
  static func normalizeProgress(latestText: String, partial: String) -> (delta: String, text: String) {
    if latestText.isEmpty {
      return (partial, partial)
    }
    if partial.hasPrefix(latestText) {
      return (String(partial.dropFirst(latestText.count)), partial)
    }
    if latestText.hasPrefix(partial) {
      return ("", latestText)
    }
    return (partial, latestText + partial)
  }
}
#endif
