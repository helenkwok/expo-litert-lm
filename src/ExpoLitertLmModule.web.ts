/*
 * Copyright (c) 2026 Helen Kwok
 * SPDX-License-Identifier: MIT
 *
 * Web implementation of the ExpoLitertLm native module. Backed by Google's
 * first-party @litert-lm/core package (v0.12.0+, WebGPU/CPU). Mirrors the
 * NativeExpoLitertLmModule interface in src/index.ts so the JS API surface is
 * identical to iOS/Android.
 *
 * Spike scope (parallel to the iOS v0.12.0 spike on feat/litert-v0.12):
 *   - Text-only generation works end-to-end.
 *   - Audio / multimodal paths throw "not yet supported in v0.12.0 spike".
 *   - Model is loaded from a URL string (Engine.create accepts URL or stream).
 *   - Single in-flight conversation per loaded model; subsequent
 *     generateResponseAsync calls reuse it (true conversation state, unlike
 *     the iOS spike which creates a fresh conversation per call).
 *
 * @litert-lm/core is an optionalPeerDependency — non-web consumers do not need
 * to install it. If a web build calls into this module without it installed,
 * loadModelAsync throws a clear "install @litert-lm/core" error.
 */
import type {
  LiteRtLoadResult,
  LiteRtPreferredBackend,
  LiteRtTokenEvent,
} from './index';

type LitertLmModule = typeof import('@litert-lm/core');
type EngineLike = Awaited<ReturnType<LitertLmModule['Engine']['create']>>;
type ConversationLike = Awaited<ReturnType<EngineLike['createConversation']>>;
// The Message type lives in conversation_config; we only need to read text out
// of message.content entries, so a structural type is enough.
type MessageLike = {
  content: Array<{ type: string; text?: string }>;
};

type LoadConfig = {
  modelPath: string;
  maxTokens: number;
  topK: number;
  temperature: number;
  preferredBackend: LiteRtPreferredBackend;
};

type Listener = (event: LiteRtTokenEvent) => void;

class ExpoLitertLmWebModule {
  private litertLm: LitertLmModule | null = null;
  private engine: EngineLike | null = null;
  private conversation: ConversationLike | null = null;
  private loadConfig: LoadConfig | null = null;
  private activeGenerationId: number = 0;
  private listeners = new Set<Listener>();

  // ---- NativeExpoLitertLmModule shape ----

  async isAvailableAsync(): Promise<boolean> {
    if (typeof window === 'undefined') return false;
    // WebGPU is required for the @litert-lm/core 'gpu' backend. CPU backend
    // works without it, but the package itself is webgpu-prefer.
    // crossOriginIsolated is required for SharedArrayBuffer (which the WASM
    // runtime uses for threading).
    const hasNav = typeof navigator !== 'undefined';
    const hasGpu = hasNav && 'gpu' in navigator;
    const isCOI = typeof (globalThis as { crossOriginIsolated?: boolean })
      .crossOriginIsolated === 'boolean'
      ? (globalThis as { crossOriginIsolated?: boolean }).crossOriginIsolated === true
      : false;
    return hasGpu && isCOI;
  }

  async sampleMemoryAsync(): Promise<number> {
    // Chromium-only `performance.memory.usedJSHeapSize` in MB. Other browsers
    // return 0 (no comparable API). Native parity: iOS uses Mach
    // task_info / phys_footprint; not available in JS.
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

    // Same-config early return — matches native behaviour.
    if (
      this.engine &&
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

    const litertLm = await this.requireLitertLm();
    // Backend enum on the web package: 'cpu' | 'gpu'. We map 'default' to
    // 'gpu' (the package's own default) so the consumer's 'default' choice
    // gets WebGPU when available — falling back to CPU is the package's
    // internal decision.
    const backend = resolvedBackend === 'cpu' ? litertLm.Backend.CPU : litertLm.Backend.GPU;

    const engine = await litertLm.Engine.create({
      model: modelPath,
      backend,
      mainExecutorSettings: {
        maxNumTokens: maxTokens > 0 ? maxTokens : undefined,
      },
    });

    const conversation = await engine.createConversation();

    this.litertLm = litertLm;
    this.engine = engine;
    this.conversation = conversation;
    this.loadConfig = nextConfig;

    return { modelPath, backend: resolvedBackend };
  }

  async generateResponseAsync(prompt: string): Promise<string> {
    if (!this.engine || !this.conversation) {
      throw new Error('No LiteRT model loaded.');
    }
    const generationId = ++this.activeGenerationId;
    const conversation = this.conversation;

    let latestText = '';
    try {
      const stream = conversation.sendMessageStreaming(prompt);
      // ReadableStream<Message> — async-iterable in modern browsers, but
      // older bundlers may not polyfill it. Use a manual reader for safety.
      const reader = stream.getReader();
      try {
        while (true) {
          const { value: chunk, done } = await reader.read();
          if (done) break;
          if (this.activeGenerationId !== generationId) {
            throw new Error('LiteRT generation was cancelled.');
          }
          const delta = extractText(chunk as MessageLike);
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

  async generateAudioResponseAsync(
    _audioPath: string,
    _prompt: string
  ): Promise<string> {
    // Mirrors the iOS spike: text-only scope. Audio Scribe on web uses
    // Message multimodal content; wiring follows once text path is verified.
    throw new Error(
      'LiteRT Audio Scribe is not yet wired in the v0.12.0 web spike. Tracked in follow-up.'
    );
  }

  async cancelGenerateResponseAsync(): Promise<void> {
    // Invalidate the generation ID first — the reader loop checks this and
    // throws "was cancelled" at the next iteration. Then ask the runtime to
    // stop producing tokens.
    this.activeGenerationId++;
    try {
      this.conversation?.cancel();
    } catch {
      // cancel() throws if there's no active generation; safe to ignore.
    }
  }

  async unloadModelAsync(): Promise<void> {
    await this.unloadInternal();
  }

  // ---- onToken event-emitter shim ----

  addListener(_eventName: string, listener: Listener): { remove: () => void } {
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
        // Don't let a misbehaving listener kill the generation loop.
        // eslint-disable-next-line no-console
        console.warn('[expo-litert-lm] onToken listener threw:', e);
      }
    }
  }

  // ---- Internals ----

  private async unloadInternal(): Promise<void> {
    this.activeGenerationId++;
    if (this.conversation) {
      try {
        await this.conversation.delete();
      } catch {
        // Best-effort.
      }
      this.conversation = null;
    }
    if (this.engine) {
      try {
        await this.engine.delete();
      } catch {
        // Best-effort.
      }
      this.engine = null;
    }
    this.loadConfig = null;
  }

  private async requireLitertLm(): Promise<LitertLmModule> {
    if (this.litertLm) return this.litertLm;
    try {
      // Dynamic import so this module loads cleanly even if @litert-lm/core
      // is not installed — failure surfaces here, in loadModelAsync, with a
      // clear actionable error.
      const mod = (await import('@litert-lm/core')) as LitertLmModule;
      this.litertLm = mod;
      return mod;
    } catch (e) {
      throw new Error(
        'expo-litert-lm: web support requires `@litert-lm/core` (>=0.12.0). ' +
        'Install it as a dependency: `npm i @litert-lm/core`. ' +
        `Underlying error: ${e instanceof Error ? e.message : String(e)}`
      );
    }
  }
}

function extractText(message: MessageLike): string {
  if (!message?.content) return '';
  let s = '';
  for (const item of message.content) {
    if (item.type === 'text' && typeof item.text === 'string') {
      s += item.text;
    }
  }
  return s;
}

// Singleton — matches the native module shape, which is a single
// process-wide actor.
const expoLitertLmWebModule = new ExpoLitertLmWebModule();
export default expoLitertLmWebModule;
