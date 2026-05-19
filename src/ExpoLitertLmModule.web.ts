/*
 * Copyright (c) 2026 Helen Kwok
 * SPDX-License-Identifier: MIT
 *
 * Web implementation of the ExpoLitertLm native module. Mirrors the
 * NativeExpoLitertLmModule interface in src/index.ts so the JS API surface is
 * identical to iOS/Android.
 *
 * Two-runtime architecture (parallel to native):
 *
 *   .litertlm  →  @litert-lm/core         (LiteRT-LM path; matches iOS Core /
 *                                          Android default)
 *   .task      →  @mediapipe/tasks-genai  (MediaPipe Tasks GenAI path; matches
 *                                          iOS MediaPipeFallback subspec /
 *                                          Android MediaPipe path)
 *
 * Routing is by **magic-byte sniff** on the first 8 bytes of the model URL:
 *   - "LITERTLM" → LiteRT-LM runtime
 *   - "PK\x03\x04" (ZIP, MediaPipe Tasks GenAI uses zip-packaged models)
 *                  → MediaPipe runtime
 *
 * Both packages are optionalPeerDependencies — non-web consumers don't pay
 * the bundle cost of either. Each runtime is lazy-imported only when its
 * matching file format is requested.
 *
 * Spike scope (parallel to the iOS v0.12.0 spike):
 *   - Text-only generation works end-to-end on both runtimes.
 *   - Audio / multimodal paths throw "not yet supported in v0.12.0 spike".
 */
import type {
  LiteRtLoadResult,
  LiteRtPreferredBackend,
  LiteRtTokenEvent,
} from './index';

// --- Loaded-module typing ---

type LitertLmModule = typeof import('@litert-lm/core');
type LitertLmEngine = Awaited<ReturnType<LitertLmModule['Engine']['create']>>;
type LitertLmConversation = Awaited<
  ReturnType<LitertLmEngine['createConversation']>
>;
type LitertLmMessageLike = {
  content: Array<{ type: string; text?: string }>;
};

type MediaPipeModule = typeof import('@mediapipe/tasks-genai');
type MediaPipeLlmInference = Awaited<
  ReturnType<MediaPipeModule['LlmInference']['createFromOptions']>
>;

type Runtime = 'litert-lm' | 'mediapipe';

type LoadConfig = {
  modelPath: string;
  maxTokens: number;
  topK: number;
  temperature: number;
  preferredBackend: LiteRtPreferredBackend;
};

type Listener = (event: LiteRtTokenEvent) => void;

// --- Singleton module ---

class ExpoLitertLmWebModule {
  // Lazy-loaded peer dep references.
  private litertLm: LitertLmModule | null = null;
  private mediaPipe: MediaPipeModule | null = null;

  // Engine state — only one runtime active at a time.
  private runtime: Runtime | null = null;
  private litertLmEngine: LitertLmEngine | null = null;
  private litertLmConversation: LitertLmConversation | null = null;
  private mediaPipeLlm: MediaPipeLlmInference | null = null;

  private loadConfig: LoadConfig | null = null;
  private activeGenerationId: number = 0;
  private listeners = new Set<Listener>();

  // ---- NativeExpoLitertLmModule shape ----

  async isAvailableAsync(): Promise<boolean> {
    if (typeof window === 'undefined') return false;
    const hasGpu =
      typeof navigator !== 'undefined' && 'gpu' in navigator;
    const isCOI =
      typeof (globalThis as { crossOriginIsolated?: boolean })
        .crossOriginIsolated === 'boolean'
        ? (globalThis as { crossOriginIsolated?: boolean })
            .crossOriginIsolated === true
        : false;
    return hasGpu && isCOI;
  }

  async sampleMemoryAsync(): Promise<number> {
    const perf = (globalThis as {
      performance?: { memory?: { usedJSHeapSize?: number } };
    }).performance;
    const heap = perf?.memory?.usedJSHeapSize;
    return typeof heap === 'number' ? heap / 1024 / 1024 : 0;
  }

  async loadModelAsync(
    modelPath: string,
    maxTokens: number,
    topK: number,
    temperature: number,
    preferredBackend?: LiteRtPreferredBackend
  ): Promise<LiteRtLoadResult> {
    const resolvedBackend: LiteRtPreferredBackend = preferredBackend ?? 'default';
    const nextConfig: LoadConfig = {
      modelPath,
      maxTokens,
      topK,
      temperature,
      preferredBackend: resolvedBackend,
    };

    if (
      this.runtime &&
      this.loadConfig &&
      this.loadConfig.modelPath === nextConfig.modelPath &&
      this.loadConfig.maxTokens === nextConfig.maxTokens &&
      this.loadConfig.topK === nextConfig.topK &&
      this.loadConfig.temperature === nextConfig.temperature &&
      this.loadConfig.preferredBackend === nextConfig.preferredBackend
    ) {
      return { modelPath, backend: resolvedBackend };
    }

    await this.unloadInternal();

    const runtime = await sniffRuntime(modelPath);

    if (runtime === 'litert-lm') {
      await this.loadLitertLm(modelPath, maxTokens, resolvedBackend);
    } else {
      await this.loadMediaPipe(
        modelPath,
        maxTokens,
        topK,
        temperature,
        resolvedBackend
      );
    }

    this.runtime = runtime;
    this.loadConfig = nextConfig;
    return { modelPath, backend: resolvedBackend };
  }

  async generateResponseAsync(prompt: string): Promise<string> {
    if (!this.runtime) {
      throw new Error('No LiteRT model loaded.');
    }
    const generationId = ++this.activeGenerationId;

    if (this.runtime === 'litert-lm') {
      return this.generateLitertLm(prompt, generationId);
    }
    return this.generateMediaPipe(prompt, generationId);
  }

  async generateAudioResponseAsync(
    _audioPath: string,
    _prompt: string
  ): Promise<string> {
    throw new Error(
      'LiteRT Audio Scribe is not yet wired in the v0.12.0 web spike. Tracked in follow-up.'
    );
  }

  async cancelGenerateResponseAsync(): Promise<void> {
    this.activeGenerationId++;
    if (this.runtime === 'litert-lm') {
      try {
        this.litertLmConversation?.cancel();
      } catch {
        // ignore — cancel() throws if there's no active generation
      }
    }
    // @mediapipe LlmInference does not expose a runtime cancel — the gate via
    // activeGenerationId in the progressListener breaks the await loop.
  }

  async unloadModelAsync(): Promise<void> {
    await this.unloadInternal();
  }

  // ---- onToken event-emitter shim ----

  addListener(
    _eventName: string,
    listener: Listener
  ): { remove: () => void } {
    this.listeners.add(listener);
    return {
      remove: () => {
        this.listeners.delete(listener);
      },
    };
  }

  private emit(event: LiteRtTokenEvent): void {
    for (const l of this.listeners) {
      try {
        l(event);
      } catch (e) {
        // eslint-disable-next-line no-console
        console.warn('[expo-litert-lm] onToken listener threw:', e);
      }
    }
  }

  // ---- LiteRT-LM runtime ----

  private async loadLitertLm(
    modelPath: string,
    maxTokens: number,
    preferredBackend: LiteRtPreferredBackend
  ): Promise<void> {
    const litertLm = await this.requireLitertLm();
    const backend =
      preferredBackend === 'cpu' ? litertLm.Backend.CPU : litertLm.Backend.GPU;

    const engine = await litertLm.Engine.create({
      model: modelPath,
      backend,
      mainExecutorSettings: {
        maxNumTokens: maxTokens > 0 ? maxTokens : undefined,
      },
    });
    const conversation = await engine.createConversation();
    this.litertLmEngine = engine;
    this.litertLmConversation = conversation;
  }

  private async generateLitertLm(
    prompt: string,
    generationId: number
  ): Promise<string> {
    const conversation = this.litertLmConversation;
    if (!conversation) throw new Error('No LiteRT model loaded.');

    let latestText = '';
    try {
      const stream = conversation.sendMessageStreaming(prompt);
      const reader = stream.getReader();
      try {
        while (true) {
          const { value: chunk, done } = await reader.read();
          if (done) break;
          if (this.activeGenerationId !== generationId) {
            throw new Error('LiteRT generation was cancelled.');
          }
          const delta = (chunk as LitertLmMessageLike)?.content
            ? extractText(chunk as LitertLmMessageLike)
            : '';
          if (delta.length > 0) {
            latestText += delta;
            this.emit({ text: latestText, delta, done: false });
          }
        }
      } finally {
        reader.releaseLock();
      }
      if (this.activeGenerationId !== generationId) {
        throw new Error('LiteRT generation was cancelled.');
      }
      this.emit({ text: latestText, delta: '', done: true });
      return latestText;
    } catch (e) {
      if (this.activeGenerationId !== generationId) {
        throw new Error('LiteRT generation was cancelled.');
      }
      throw e;
    }
  }

  // ---- MediaPipe Tasks GenAI runtime ----

  private async loadMediaPipe(
    modelPath: string,
    maxTokens: number,
    topK: number,
    temperature: number,
    preferredBackend: LiteRtPreferredBackend
  ): Promise<void> {
    const mp = await this.requireMediaPipe();
    const wasmFileset = await mp.FilesetResolver.forGenAiTasks(
      // Default: jsDelivr CDN. Consumers can override by re-injecting
      // FilesetResolver with their own basePath before calling loadModelAsync,
      // but for the spike's MVP shape we accept this default.
      'https://cdn.jsdelivr.net/npm/@mediapipe/tasks-genai/wasm'
    );

    // MediaPipe accepts either a Uint8Array OR a ReadableStreamDefaultReader
    // for `modelAssetBuffer`. We use a stream reader so that large models
    // (multi-GB) are pulled in chunks instead of materialising the whole file
    // as a single JS-heap allocation — `File.arrayBuffer()` and
    // `Response.arrayBuffer()` choke on ~2.8 GB+ files in current browsers.
    const response = await fetch(modelPath);
    if (!response.ok) {
      throw new Error(
        `Failed to fetch .task model from ${modelPath}: HTTP ${response.status}`
      );
    }
    if (!response.body) {
      throw new Error(
        `Fetch response for ${modelPath} has no body stream — cannot load model.`
      );
    }
    const reader = response.body.getReader();

    const delegate: 'CPU' | 'GPU' =
      preferredBackend === 'cpu' ? 'CPU' : 'GPU';

    const llm = await mp.LlmInference.createFromOptions(wasmFileset, {
      baseOptions: { modelAssetBuffer: reader, delegate },
      maxTokens: maxTokens > 0 ? maxTokens : 512,
      topK: topK > 0 ? topK : 40,
      temperature: temperature >= 0 ? temperature : 0.7,
    });

    this.mediaPipeLlm = llm;
  }

  private async generateMediaPipe(
    prompt: string,
    generationId: number
  ): Promise<string> {
    const llm = this.mediaPipeLlm;
    if (!llm) throw new Error('No LiteRT model loaded.');

    // `generateResponse(prompt, listener)` returns Promise<string> with the
    // full response. The listener is called for streaming chunks when
    // streaming is supported by this MediaPipe build/model. Some builds only
    // fire the listener once with (fullText, done=true). We capture both: the
    // listener feeds onToken deltas progressively, AND we await the returned
    // Promise so the full text is the source of truth.
    let latestText = '';
    let sawStreamingChunk = false;
    const fullText = await llm.generateResponse(
      prompt,
      (partialResult: string, _done: boolean) => {
        if (this.activeGenerationId !== generationId) return;
        if (partialResult && partialResult.length > 0) {
          sawStreamingChunk = true;
          latestText += partialResult;
          this.emit({
            text: latestText,
            delta: partialResult,
            done: false,
          });
        }
      }
    );
    if (this.activeGenerationId !== generationId) {
      throw new Error('LiteRT generation was cancelled.');
    }
    if (!sawStreamingChunk && typeof fullText === 'string' && fullText.length > 0) {
      // No streaming — emit the whole response as one delta.
      latestText = fullText;
      this.emit({ text: latestText, delta: fullText, done: false });
    }
    this.emit({ text: latestText, delta: '', done: true });
    return latestText;
  }

  // ---- Lazy peer-dep imports ----

  private async requireLitertLm(): Promise<LitertLmModule> {
    if (this.litertLm) return this.litertLm;
    try {
      const mod = (await import('@litert-lm/core')) as LitertLmModule;
      this.litertLm = mod;
      return mod;
    } catch (e) {
      throw new Error(
        'expo-litert-lm: web .litertlm support requires `@litert-lm/core` (>=0.12.0). ' +
          'Install it: `npm i @litert-lm/core`. ' +
          `Underlying error: ${e instanceof Error ? e.message : String(e)}`
      );
    }
  }

  private async requireMediaPipe(): Promise<MediaPipeModule> {
    if (this.mediaPipe) return this.mediaPipe;
    try {
      const mod = (await import('@mediapipe/tasks-genai')) as MediaPipeModule;
      this.mediaPipe = mod;
      return mod;
    } catch (e) {
      throw new Error(
        'expo-litert-lm: web .task support requires `@mediapipe/tasks-genai` (>=0.10.27). ' +
          'Install it: `npm i @mediapipe/tasks-genai`. ' +
          `Underlying error: ${e instanceof Error ? e.message : String(e)}`
      );
    }
  }

  // ---- Internals ----

  private async unloadInternal(): Promise<void> {
    this.activeGenerationId++;
    if (this.litertLmConversation) {
      try {
        await this.litertLmConversation.delete();
      } catch {
        // best-effort
      }
      this.litertLmConversation = null;
    }
    if (this.litertLmEngine) {
      try {
        await this.litertLmEngine.delete();
      } catch {
        // best-effort
      }
      this.litertLmEngine = null;
    }
    if (this.mediaPipeLlm) {
      try {
        this.mediaPipeLlm.close();
      } catch {
        // best-effort
      }
      this.mediaPipeLlm = null;
    }
    this.runtime = null;
    this.loadConfig = null;
  }
}

function extractText(message: { content: Array<{ type: string; text?: string }> }): string {
  if (!message?.content) return '';
  let s = '';
  for (const item of message.content) {
    if (item.type === 'text' && typeof item.text === 'string') {
      s += item.text;
    }
  }
  return s;
}

/**
 * Inspect the first 8 bytes of the model URL to decide which runtime to use.
 *
 * - `.litertlm` files start with the 8-byte ASCII magic `LITERTLM`
 *   (0x4c 0x49 0x54 0x45 0x52 0x54 0x4c 0x4d).
 * - `.task` files used by MediaPipe Tasks GenAI come in two flavours:
 *     1. Raw TFLite flatbuffer — 4-byte little-endian length prefix, then
 *        the `TFL3` magic at offset 4 (0x54 0x46 0x4c 0x33). This is what
 *        recent `litert-community/*` `.task` files use (verified 2026-05-19
 *        on gemma3-1b-it-int4-web.task).
 *     2. Legacy ZIP archive — magic `PK\x03\x04` (0x50 0x4b 0x03 0x04).
 *        Kept for backward compat with older MediaPipe model bundles.
 *
 * Sniffing by content rather than by filename also works for blob: URLs
 * (which carry no filename) and for renamed files.
 */
async function sniffRuntime(modelPath: string): Promise<Runtime> {
  let head: Uint8Array;
  try {
    const resp = await fetch(modelPath, { headers: { Range: 'bytes=0-15' } });
    if (!resp.ok && resp.status !== 206) {
      throw new Error(`HTTP ${resp.status} fetching model header`);
    }
    head = new Uint8Array(await resp.arrayBuffer());
  } catch (e) {
    throw new Error(
      `expo-litert-lm: could not read model header from ${modelPath}: ${
        e instanceof Error ? e.message : String(e)
      }`
    );
  }

  // LITERTLM at offset 0
  if (
    head.length >= 8 &&
    head[0] === 0x4c && head[1] === 0x49 && head[2] === 0x54 && head[3] === 0x45 &&
    head[4] === 0x52 && head[5] === 0x54 && head[6] === 0x4c && head[7] === 0x4d
  ) {
    return 'litert-lm';
  }
  // TFL3 at offset 4 — raw TFLite flatbuffer container (recent MediaPipe .task)
  if (
    head.length >= 8 &&
    head[4] === 0x54 && head[5] === 0x46 && head[6] === 0x4c && head[7] === 0x33
  ) {
    return 'mediapipe';
  }
  // PK\x03\x04 at offset 0 — ZIP archive (legacy MediaPipe .task)
  if (
    head.length >= 4 &&
    head[0] === 0x50 && head[1] === 0x4b && head[2] === 0x03 && head[3] === 0x04
  ) {
    return 'mediapipe';
  }
  throw new Error(
    `expo-litert-lm: model at ${modelPath} is not a recognised format. ` +
      `Expected LITERTLM (.litertlm), TFL3 at offset 4 (.task), or PK ZIP (.task legacy). ` +
      `First 16 bytes: ${Array.from(head.slice(0, 16))
        .map((b) => b.toString(16).padStart(2, '0'))
        .join(' ')}`
  );
}

const expoLitertLmWebModule = new ExpoLitertLmWebModule();
export default expoLitertLmWebModule;
