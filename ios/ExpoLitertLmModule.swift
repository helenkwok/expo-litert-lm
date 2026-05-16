import ExpoModulesCore
import Foundation
// LiteRTLMSwift sources are vendored under ios/Sources/LiteRTLMSwift/ and
// compiled into the ExpoLitertLm pod module (podspec Core subspec source_files
// glob picks them up). No separate `LiteRTLMSwift` Swift module exists in the
// Pod consumer path — types like LiteRTLMEngine are visible at this scope.

private struct LiteRtLoadConfig: Equatable {
  let maxTokens: Int
  let modelPath: String
  let preferredBackend: String
  let temperature: Double
  let topK: Int
}

private struct LiteRtModuleError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

private enum LoadedRuntime {
  case litertLm
  case mediaPipe
}

public final class ExpoLitertLmModule: Module {
  // Engine handles per runtime. Only one is non-nil at a time.
  private var litertLmEngine: LiteRTLMEngine?
  #if EXPO_LITERTLM_MEDIAPIPE_FALLBACK
  private var mediaPipeFallback: MediaPipeFallbackEngine?
  #endif

  private var loadedRuntime: LoadedRuntime?
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

    // Phase 14 Stage B (D-07): JS-readable phys_footprint sampler. Same Mach
    // kernel data the iOS jetsam path uses for OOM decisions; returned in MB
    // for JS-friendliness.
    AsyncFunction("sampleMemoryAsync") { () -> Double in
      return Double(MemoryProbe.currentPhysFootprint()) / 1024.0 / 1024.0
    }

    AsyncFunction("loadModelAsync") { (
      modelPath: String,
      maxTokens: Int,
      topK: Int,
      temperature: Double,
      preferredBackend: String?
    ) -> [String: String] in
      try self.ensureSupportedOS()

      let resolvedBackend = (preferredBackend ?? "cpu").lowercased()
      let nextConfig = LiteRtLoadConfig(
        maxTokens: maxTokens,
        modelPath: modelPath,
        preferredBackend: resolvedBackend,
        temperature: temperature,
        topK: topK
      )

      // Same-config early return — preserves the pre-rewrite behaviour.
      if self.loadedConfig == nextConfig, self.loadedRuntime != nil {
        return [
          "backend": resolvedBackend,
          "modelPath": modelPath,
        ]
      }

      self.cancelActiveGeneration()
      await self.unloadInternalAsync()

      if Self.isLiteRtLmModelPath(modelPath) {
        // LiteRTLM-Swift path — default for `.litertlm` models.
        let engine = LiteRTLMEngine(
          modelPath: URL(fileURLWithPath: modelPath),
          backend: resolvedBackend
        )
        do {
          try await engine.load()
        } catch {
          throw LiteRtModuleError(
            message: self.message(from: error, fallback: "LiteRT model loading failed.")
          )
        }
        self.litertLmEngine = engine
        self.loadedRuntime = .litertLm
      } else {
        // Non-`.litertlm` path routes to MediaPipe only when the fallback
        // subspec is compiled in. Default install rejects with a clear
        // opt-in message.
        #if EXPO_LITERTLM_MEDIAPIPE_FALLBACK
        let engine = MediaPipeFallbackEngine()
        do {
          try engine.load(
            modelPath: modelPath,
            maxTokens: maxTokens,
            topK: topK,
            temperature: temperature,
            preferredBackend: resolvedBackend
          )
        } catch {
          throw LiteRtModuleError(
            message: self.message(from: error, fallback: "MediaPipe model loading failed.")
          )
        }
        self.mediaPipeFallback = engine
        self.loadedRuntime = .mediaPipe
        #else
        throw LiteRtModuleError(
          message: ".task models require the MediaPipeFallback subspec. Add `pod 'ExpoLitertLm', :subspecs => ['Core', 'MediaPipeFallback']` to your Podfile per ExpoLitertLm CHANGELOG v0.2.0."
        )
        #endif
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

      let generationID = self.beginGeneration()
      defer { self.endGeneration(generationID) }

      switch self.loadedRuntime {
      case .litertLm:
        guard let engine = self.litertLmEngine else {
          throw LiteRtModuleError(message: "No LiteRT model loaded.")
        }
        return try await self.runLitertLmGeneration(
          engine: engine,
          prompt: prompt,
          generationID: generationID
        )

      case .mediaPipe:
        #if EXPO_LITERTLM_MEDIAPIPE_FALLBACK
        guard let engine = self.mediaPipeFallback else {
          throw LiteRtModuleError(message: "No LiteRT model loaded.")
        }
        do {
          return try await engine.generate(
            prompt: prompt,
            isActive: { self.isGenerationActive(generationID) },
            emit: { text, delta, done in
              await self.emitTokenEvent(text: text, delta: delta, done: done)
            }
          )
        } catch {
          if !self.isGenerationActive(generationID) {
            throw LiteRtModuleError(message: "LiteRT generation was cancelled.")
          }
          throw LiteRtModuleError(
            message: self.message(from: error, fallback: "LiteRT generation failed.")
          )
        }
        #else
        throw LiteRtModuleError(message: "No LiteRT model loaded.")
        #endif

      case .none:
        throw LiteRtModuleError(message: "No LiteRT model loaded.")
      }
    }

    AsyncFunction("generateAudioResponseAsync") { (_: String, _: String) -> String in
      // LiteRTLM-Swift exposes an `audio()` method on LiteRTLMEngine, but
      // Phase 14 is chat-only spike scope — Audio Scribe iOS wiring lands in
      // Phase 16. Preserve the throws-stub matching the pre-rewrite contract.
      throw LiteRtModuleError(
        message: "LiteRT Audio Scribe is not available on iOS yet."
      )
    }

    AsyncFunction("cancelGenerateResponseAsync") {
      // UUID nil-out gives at-next-iteration cancellation. The LiteRTLM-Swift
      // streaming API runs the C callback on its own inferenceQueue and we
      // can't yank it mid-call, but yielding the next chunk causes our gate
      // check to throw `cancelled` which terminates the async-for loop.
      self.cancelActiveGeneration()
    }

    AsyncFunction("unloadModelAsync") {
      self.cancelActiveGeneration()
      await self.unloadInternalAsync()
    }

    OnDestroy {
      self.cancelActiveGeneration()
      // OnDestroy can't await — use the sync teardown which skips the engine's
      // @MainActor unload. The engine's deinit re-queues the C deletes on its
      // inferenceQueue so memory cleanup still runs.
      self.unloadInternalSync()
    }
  }

  // MARK: - Path routing

  private static func isLiteRtLmModelPath(_ modelPath: String) -> Bool {
    (modelPath as NSString).pathExtension.lowercased() == "litertlm"
  }

  // MARK: - LiteRTLM-Swift generation

  private func runLitertLmGeneration(
    engine: LiteRTLMEngine,
    prompt: String,
    generationID: UUID
  ) async throws -> String {
    var latestText = ""
    let temperature = Float(self.loadedConfig?.temperature ?? 0.7)
    let maxTokens = self.loadedConfig?.maxTokens ?? 512

    do {
      let stream = engine.generateStreaming(
        prompt: prompt,
        temperature: temperature,
        maxTokens: maxTokens
      )
      for try await chunk in stream {
        if !self.isGenerationActive(generationID) {
          throw LiteRtModuleError(message: "LiteRT generation was cancelled.")
        }
        // LiteRTLM-Swift yields delta chunks already — no cumulative-prefix
        // normalisation needed (contrast MediaPipe which yields cumulative
        // text and uses MediaPipeFallbackEngine.normalizeProgress).
        if !chunk.isEmpty {
          latestText.append(chunk)
          await self.emitTokenEvent(text: latestText, delta: chunk, done: false)
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

  // MARK: - Lifecycle helpers

  private func ensureSupportedOS() throws {
    if #available(iOS 17.0, tvOS 17.0, *) { return }
    throw LiteRtModuleError(message: "LiteRT models require iOS 17 or newer.")
  }

  private func beginGeneration() -> UUID {
    let nextID = UUID()
    stateQueue.sync { activeGenerationID = nextID }
    return nextID
  }

  private func endGeneration(_ generationID: UUID) {
    stateQueue.sync {
      if activeGenerationID == generationID { activeGenerationID = nil }
    }
  }

  private func isGenerationActive(_ generationID: UUID) -> Bool {
    stateQueue.sync { activeGenerationID == generationID }
  }

  private func cancelActiveGeneration() {
    stateQueue.sync { activeGenerationID = nil }
  }

  /// Async unload — invokes @MainActor LiteRTLMEngine.unload() before nilling
  /// references. Use in async contexts (loadModelAsync, unloadModelAsync).
  private func unloadInternalAsync() async {
    if let engine = litertLmEngine {
      await MainActor.run { engine.unload() }
    }
    unloadInternalSync()
  }

  /// Synchronous unload — drops references only. The LiteRTLMEngine deinit
  /// queues the C deletes on its inferenceQueue, so memory still releases.
  /// Use in non-async contexts (OnDestroy).
  private func unloadInternalSync() {
    litertLmEngine = nil
    #if EXPO_LITERTLM_MEDIAPIPE_FALLBACK
    mediaPipeFallback?.unload()
    mediaPipeFallback = nil
    #endif
    loadedRuntime = nil
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
}
