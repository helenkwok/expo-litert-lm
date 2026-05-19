import ExpoModulesCore
import Foundation
// Google's first-party LiteRT-LM Swift sources are vendored under
// ios/Sources/LiteRTLM/ (Apache 2.0, see NOTICE). They compile into the
// ExpoLitertLm pod module via the podspec source_files glob — no separate
// `LiteRTLM` Swift module exists in the Pod consumer path, so types like
// `Engine`, `EngineConfig`, `Conversation`, and `Message` are visible at this
// scope without an import.
//
// v0.12.0 spike (feat/litert-v0.12) scope:
//   - Text-only generation works end-to-end.
//   - Vision / audio / multimodal / session / conversation-history paths are
//     stubbed and throw "not yet supported in v0.12.0 spike" with a tracking
//     reference. Wiring follows once text path is verified on SE 3rd gen.

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
  // v0.12.0: `Engine` is an `actor`, so all calls must be `await`-ed.
  private var litertLmEngine: Engine?
  #if EXPO_LITERTLM_MEDIAPIPE_FALLBACK
  private var mediaPipeFallback: MediaPipeFallbackEngine?
  #endif

  private var loadedRuntime: LoadedRuntime?
  private var loadedConfig: LiteRtLoadConfig?
  private var loadedModelPath: String?
  private var securityScopedModelURL: URL?

  private let stateQueue = DispatchQueue(label: "expo.modules.litertlm.state")
  private var activeGenerationID: UUID?
  // Holds the in-flight Conversation so cancelGenerateResponseAsync can invoke
  // its native cancel(). UUID-gating remains as a secondary at-next-iteration
  // break; conversation.cancel() is the primary mechanism.
  private var activeConversation: Conversation?

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
      let modelURL = try Self.resolveModelURL(modelPath)
      let resolvedModelPath = modelURL.path
      let nextConfig = LiteRtLoadConfig(
        maxTokens: maxTokens,
        modelPath: resolvedModelPath,
        preferredBackend: resolvedBackend,
        temperature: temperature,
        topK: topK
      )

      // Same-config early return — preserves the pre-rewrite behaviour.
      if self.loadedConfig == nextConfig, self.loadedRuntime != nil {
        return [
          "backend": resolvedBackend,
          "modelPath": resolvedModelPath,
        ]
      }

      self.cancelActiveGeneration()
      await self.unloadInternalAsync()

      let didStartSecurityScope = modelURL.startAccessingSecurityScopedResource()
      var shouldStopSecurityScopeOnExit = didStartSecurityScope

      if Self.isLiteRtLmModelPath(resolvedModelPath) {
        // First-party Google LiteRT-LM path — default for `.litertlm` models.
        //
        // visionBackend/audioBackend left nil = text-only model load. The
        // v1.1 floor-device model (gemma3-1b-it-int4.litertlm) has no
        // vision/audio encoders, and the v0.12.0 spike is text-only scope —
        // multimodal wiring is tracked separately.
        let backend: Backend = (resolvedBackend == "gpu") ? .gpu : .cpu()

        let engineConfig: EngineConfig
        do {
          engineConfig = try EngineConfig(
            modelPath: resolvedModelPath,
            backend: backend,
            visionBackend: nil,
            audioBackend: nil,
            maxNumTokens: maxTokens > 0 ? maxTokens : nil,
            cacheDir: nil
          )
        } catch {
          if shouldStopSecurityScopeOnExit {
            modelURL.stopAccessingSecurityScopedResource()
          }
          throw LiteRtModuleError(
            message: self.message(from: error, fallback: "LiteRT EngineConfig rejected.")
          )
        }

        let engine = Engine(engineConfig: engineConfig)
        do {
          // Engine.initialize() is `throws` (not async) but is called via the
          // actor — `await` here routes it onto the actor's executor (off the
          // main thread). Google notes this call "can take a significant
          // amount of time (e.g., 10 seconds)"; AsyncFunction already runs on
          // Expo's background scheduler, so no extra detached Task is needed.
          try await engine.initialize()
        } catch {
          if shouldStopSecurityScopeOnExit {
            modelURL.stopAccessingSecurityScopedResource()
          }
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
            modelPath: resolvedModelPath,
            maxTokens: maxTokens,
            topK: topK,
            temperature: temperature,
            preferredBackend: resolvedBackend
          )
        } catch {
          if shouldStopSecurityScopeOnExit {
            modelURL.stopAccessingSecurityScopedResource()
          }
          throw LiteRtModuleError(
            message: self.message(from: error, fallback: "MediaPipe model loading failed.")
          )
        }
        self.mediaPipeFallback = engine
        self.loadedRuntime = .mediaPipe
        #else
        if shouldStopSecurityScopeOnExit {
          modelURL.stopAccessingSecurityScopedResource()
        }
        throw LiteRtModuleError(
          message: ".task models require the MediaPipeFallback subspec. Add `pod 'ExpoLitertLm', :subspecs => ['Core', 'MediaPipeFallback']` to your Podfile per ExpoLitertLm CHANGELOG v0.2.0."
        )
        #endif
      }

      self.loadedConfig = nextConfig
      self.loadedModelPath = resolvedModelPath
      if didStartSecurityScope {
        self.securityScopedModelURL = modelURL
        shouldStopSecurityScopeOnExit = false
      }

      return [
        "backend": resolvedBackend,
        "modelPath": resolvedModelPath,
      ]
    }

    AsyncFunction("generateResponseAsync") { (prompt: String) async throws -> String in
      try self.ensureSupportedOS()

      let generationID = self.beginGeneration()
      defer {
        self.endGeneration(generationID)
        self.clearActiveConversation()
      }

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
      // v0.12.0 spike scope is text-only. Audio Scribe iOS wiring lands in a
      // follow-up phase using the new Message-based multimodal API
      // (Message with audio Content).
      throw LiteRtModuleError(
        message: "LiteRT Audio Scribe is not yet wired in the v0.12.0 spike (feat/litert-v0.12). Tracked in follow-up."
      )
    }

    AsyncFunction("cancelGenerateResponseAsync") {
      // v0.12.0: prefer Conversation.cancel() for prompt cancellation; the
      // UUID gate remains as a defensive secondary break (cancel() takes
      // effect at the next inference step inside the native runtime).
      await self.cancelActiveConversation()
      self.cancelActiveGeneration()
    }

    AsyncFunction("unloadModelAsync") {
      await self.cancelActiveConversation()
      self.cancelActiveGeneration()
      await self.unloadInternalAsync()
    }

    OnDestroy {
      self.cancelActiveGeneration()
      // OnDestroy can't await — clear refs synchronously. Engine actor's
      // deinit invokes litert_lm_engine_delete on the native handle, so
      // memory cleanup still runs even without an explicit unload call.
      self.unloadInternalSync()
    }
  }

  // MARK: - Path routing

  private static func isLiteRtLmModelPath(_ modelPath: String) -> Bool {
    (modelPath as NSString).pathExtension.lowercased() == "litertlm"
  }

  private static func resolveModelURL(_ modelPath: String) throws -> URL {
    if modelPath.lowercased().hasPrefix("file://") {
      if let url = URL(string: modelPath), url.isFileURL {
        return url
      }

      let pathWithoutScheme = String(modelPath.dropFirst("file://".count))
      return URL(fileURLWithPath: pathWithoutScheme.removingPercentEncoding ?? pathWithoutScheme)
    }

    if modelPath.contains("://") {
      throw LiteRtModuleError(
        message: "LiteRT models must be loaded from a local path or file:// URL."
      )
    }

    return URL(fileURLWithPath: modelPath)
  }

  // MARK: - LiteRT-LM v0.12.0 generation

  private func runLitertLmGeneration(
    engine: Engine,
    prompt: String,
    generationID: UUID
  ) async throws -> String {
    var latestText = ""

    let temperature = Float(self.loadedConfig?.temperature ?? 0.7)
    let topK = max(self.loadedConfig?.topK ?? 40, 1)

    // ConversationConfig with a SamplerConfig matching the JS-supplied
    // temperature / topK. v0.12.0 moved sampler params from per-call
    // generateStreaming args to a per-conversation SamplerConfig.
    let samplerConfig: SamplerConfig?
    do {
      samplerConfig = try SamplerConfig(
        topK: topK,
        topP: 1.0,
        temperature: temperature,
        seed: 0
      )
    } catch {
      throw LiteRtModuleError(
        message: self.message(from: error, fallback: "Invalid sampler config.")
      )
    }

    let conversationConfig = ConversationConfig(samplerConfig: samplerConfig)

    let conversation: Conversation
    do {
      conversation = try await engine.createConversation(with: conversationConfig)
    } catch {
      throw LiteRtModuleError(
        message: self.message(from: error, fallback: "Failed to create LiteRT conversation.")
      )
    }
    self.setActiveConversation(conversation)

    let message = Message(prompt, role: .user)

    do {
      // Conversation is a class (not actor) in v0.12.0 — call directly.
      let stream = conversation.sendMessageStream(message)
      for try await chunk in stream {
        if !self.isGenerationActive(generationID) {
          throw LiteRtModuleError(message: "LiteRT generation was cancelled.")
        }
        // v0.12.0 yields Message chunks; .toString flattens text Content
        // entries. Assumption: chunks are deltas (matches the C-callback
        // semantics in Conversation.swift:streamCallback). Verify on first
        // device run — if cumulative, switch to last-chunk-only emit and
        // adjust the delta computation.
        let delta = chunk.toString
        if !delta.isEmpty {
          latestText.append(delta)
          await self.emitTokenEvent(text: latestText, delta: delta, done: false)
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

  private func setActiveConversation(_ conversation: Conversation) {
    stateQueue.sync { activeConversation = conversation }
  }

  private func clearActiveConversation() {
    stateQueue.sync { activeConversation = nil }
  }

  private func cancelActiveConversation() async {
    let conv = stateQueue.sync { activeConversation }
    // Conversation is a class with a sync `cancel() throws` — call directly.
    try? conv?.cancel()
  }

  /// Async unload — drops engine references; the Engine actor's deinit
  /// invokes the native engine delete.
  private func unloadInternalAsync() async {
    unloadInternalSync()
  }

  /// Synchronous unload — drops references only. The Engine actor's deinit
  /// queues the native delete; memory still releases.
  private func unloadInternalSync() {
    litertLmEngine = nil
    activeConversation = nil
    #if EXPO_LITERTLM_MEDIAPIPE_FALLBACK
    mediaPipeFallback?.unload()
    mediaPipeFallback = nil
    #endif
    loadedRuntime = nil
    loadedConfig = nil
    loadedModelPath = nil
    if let url = securityScopedModelURL {
      url.stopAccessingSecurityScopedResource()
      securityScopedModelURL = nil
    }
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
