import ExpoModulesCore
import Foundation
import MediaPipeTasksGenai

private struct LiteRtLoadConfig: Equatable {
  let maxTokens: Int
  let modelPath: String
  let preferredBackend: String
  let temperature: Double
  let topK: Int
}

private struct LiteRtProgress {
  let delta: String
  let text: String
}

private struct LiteRtModuleError: LocalizedError {
  let message: String

  var errorDescription: String? {
    message
  }
}

public final class ExpoLitertLmModule: Module {
  private var llmInference: LlmInference?
  private var loadedConfig: LiteRtLoadConfig?
  private var loadedModelPath: String?
  private let stateQueue = DispatchQueue(label: "expo.modules.litertlm.state")
  private var activeGenerationID: UUID?

  public func definition() -> ModuleDefinition {
    Name("ExpoLitertLm")
    Events("onToken")

    AsyncFunction("isAvailableAsync") { () -> Bool in
      if #available(iOS 17.0, tvOS 17.0, *) {
        return true
      }
      return false
    }

    AsyncFunction("loadModelAsync") { (
      modelPath: String,
      maxTokens: Int,
      topK: Int,
      temperature: Double,
      preferredBackend: String?
    ) -> [String: String] in
      try self.ensureSupportedOS()

      let resolvedBackend = (preferredBackend ?? "default").lowercased()
      let nextConfig = LiteRtLoadConfig(
        maxTokens: maxTokens,
        modelPath: modelPath,
        preferredBackend: resolvedBackend,
        temperature: temperature,
        topK: topK
      )

      if self.loadedConfig == nextConfig, self.llmInference != nil {
        return [
          "backend": resolvedBackend,
          "modelPath": modelPath,
        ]
      }

      self.cancelActiveGeneration()
      self.unloadInternal()

      let options = LlmInferenceOptions()
      options.baseOptions.modelPath = modelPath
      options.maxTokens = maxTokens
      options.topk = topK
      options.temperature = Float(temperature)
      options.randomSeed = Int.random(in: 1...Int(Int32.max))

      do {
        self.llmInference = try LlmInference(options: options)
      } catch {
        throw LiteRtModuleError(
          message: self.message(from: error, fallback: "LiteRT model loading failed.")
        )
      }

      self.loadedConfig = nextConfig
      self.loadedModelPath = modelPath

      return [
        "backend": resolvedBackend,
        "modelPath": modelPath,
      ]
    }

    AsyncFunction("generateResponseAsync") { (prompt: String) async throws -> String in
      try self.ensureSupportedOS()
      guard let llmInference = self.llmInference else {
        throw LiteRtModuleError(message: "No LiteRT model loaded.")
      }

      let generationID = self.beginGeneration()
      defer {
        self.endGeneration(generationID)
      }

      var latestText = ""

      do {
        let resultStream = llmInference.generateResponseAsync(inputText: prompt)
        for try await partialResult in resultStream {
          if !self.isGenerationActive(generationID) {
            throw LiteRtModuleError(message: "LiteRT generation was cancelled.")
          }

          let progress = Self.normalizeProgress(latestText: latestText, partial: partialResult)
          latestText = progress.text

          if !progress.delta.isEmpty {
            await self.emitTokenEvent(text: latestText, delta: progress.delta, done: false)
          }
        }

        if !self.isGenerationActive(generationID) {
          throw LiteRtModuleError(message: "LiteRT generation was cancelled.")
        }

        await self.emitTokenEvent(text: latestText, delta: "", done: true)
        return latestText
      } catch {
        if !self.isGenerationActive(generationID) {
          throw LiteRtModuleError(message: "LiteRT generation was cancelled.")
        }
        throw LiteRtModuleError(
          message: self.message(from: error, fallback: "LiteRT generation failed.")
        )
      }
    }

    AsyncFunction("generateAudioResponseAsync") { (_: String, _: String) -> String in
      throw LiteRtModuleError(
        message: "LiteRT Audio Scribe is not available on iOS yet."
      )
    }

    AsyncFunction("cancelGenerateResponseAsync") {
      self.cancelActiveGeneration()
    }

    AsyncFunction("unloadModelAsync") {
      self.cancelActiveGeneration()
      self.unloadInternal()
    }

    OnDestroy {
      self.cancelActiveGeneration()
      self.unloadInternal()
    }
  }

  private func ensureSupportedOS() throws {
    if #available(iOS 17.0, tvOS 17.0, *) {
      return
    }
    throw LiteRtModuleError(message: "LiteRT models require iOS 17 or newer.")
  }

  private func beginGeneration() -> UUID {
    let nextID = UUID()
    stateQueue.sync {
      activeGenerationID = nextID
    }
    return nextID
  }

  private func endGeneration(_ generationID: UUID) {
    stateQueue.sync {
      if activeGenerationID == generationID {
        activeGenerationID = nil
      }
    }
  }

  private func isGenerationActive(_ generationID: UUID) -> Bool {
    stateQueue.sync {
      activeGenerationID == generationID
    }
  }

  private func cancelActiveGeneration() {
    stateQueue.sync {
      activeGenerationID = nil
    }
  }

  private func unloadInternal() {
    llmInference = nil
    loadedConfig = nil
    loadedModelPath = nil
  }

  private func emitTokenEvent(text: String, delta: String, done: Bool) async {
    await MainActor.run {
      self.sendEvent("onToken", [
        "delta": delta,
        "done": done,
        "text": text,
      ])
    }
  }

  private func message(from error: Error, fallback: String) -> String {
    let nsError = error as NSError
    let message = nsError.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    return message.isEmpty ? fallback : message
  }

  private static func normalizeProgress(latestText: String, partial: String) -> LiteRtProgress {
    if latestText.isEmpty {
      return LiteRtProgress(delta: partial, text: partial)
    }

    if partial.hasPrefix(latestText) {
      return LiteRtProgress(
        delta: String(partial.dropFirst(latestText.count)),
        text: partial
      )
    }

    if latestText.hasPrefix(partial) {
      return LiteRtProgress(delta: "", text: latestText)
    }

    return LiteRtProgress(delta: partial, text: latestText + partial)
  }
}
