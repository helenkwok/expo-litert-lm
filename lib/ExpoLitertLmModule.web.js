"use strict";
var __createBinding = (this && this.__createBinding) || (Object.create ? (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    var desc = Object.getOwnPropertyDescriptor(m, k);
    if (!desc || ("get" in desc ? !m.__esModule : desc.writable || desc.configurable)) {
      desc = { enumerable: true, get: function() { return m[k]; } };
    }
    Object.defineProperty(o, k2, desc);
}) : (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    o[k2] = m[k];
}));
var __setModuleDefault = (this && this.__setModuleDefault) || (Object.create ? (function(o, v) {
    Object.defineProperty(o, "default", { enumerable: true, value: v });
}) : function(o, v) {
    o["default"] = v;
});
var __importStar = (this && this.__importStar) || (function () {
    var ownKeys = function(o) {
        ownKeys = Object.getOwnPropertyNames || function (o) {
            var ar = [];
            for (var k in o) if (Object.prototype.hasOwnProperty.call(o, k)) ar[ar.length] = k;
            return ar;
        };
        return ownKeys(o);
    };
    return function (mod) {
        if (mod && mod.__esModule) return mod;
        var result = {};
        if (mod != null) for (var k = ownKeys(mod), i = 0; i < k.length; i++) if (k[i] !== "default") __createBinding(result, mod, k[i]);
        __setModuleDefault(result, mod);
        return result;
    };
})();
Object.defineProperty(exports, "__esModule", { value: true });
class ExpoLitertLmWebModule {
    constructor() {
        this.litertLm = null;
        this.engine = null;
        this.conversation = null;
        this.loadConfig = null;
        this.activeGenerationId = 0;
        this.listeners = new Set();
    }
    // ---- NativeExpoLitertLmModule shape ----
    async isAvailableAsync() {
        if (typeof window === 'undefined')
            return false;
        // WebGPU is required for the @litert-lm/core 'gpu' backend. CPU backend
        // works without it, but the package itself is webgpu-prefer.
        // crossOriginIsolated is required for SharedArrayBuffer (which the WASM
        // runtime uses for threading).
        const hasNav = typeof navigator !== 'undefined';
        const hasGpu = hasNav && 'gpu' in navigator;
        const isCOI = typeof globalThis
            .crossOriginIsolated === 'boolean'
            ? globalThis.crossOriginIsolated === true
            : false;
        return hasGpu && isCOI;
    }
    async sampleMemoryAsync() {
        // Chromium-only `performance.memory.usedJSHeapSize` in MB. Other browsers
        // return 0 (no comparable API). Native parity: iOS uses Mach
        // task_info / phys_footprint; not available in JS.
        const perf = globalThis.performance;
        const heap = perf?.memory?.usedJSHeapSize;
        return typeof heap === 'number' ? heap / 1024 / 1024 : 0;
    }
    async loadModelAsync(modelPath, maxTokens, topK, temperature, preferredBackend) {
        const resolvedBackend = preferredBackend ?? 'default';
        const nextConfig = {
            modelPath,
            maxTokens,
            topK,
            temperature,
            preferredBackend: resolvedBackend,
        };
        // Same-config early return — matches native behaviour.
        if (this.engine &&
            this.loadConfig &&
            this.loadConfig.modelPath === nextConfig.modelPath &&
            this.loadConfig.maxTokens === nextConfig.maxTokens &&
            this.loadConfig.topK === nextConfig.topK &&
            this.loadConfig.temperature === nextConfig.temperature &&
            this.loadConfig.preferredBackend === nextConfig.preferredBackend) {
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
    async generateResponseAsync(prompt) {
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
                    if (done)
                        break;
                    if (this.activeGenerationId !== generationId) {
                        throw new Error('LiteRT generation was cancelled.');
                    }
                    const delta = extractText(chunk);
                    if (delta.length > 0) {
                        latestText += delta;
                        this.emit({ text: latestText, delta, done: false });
                    }
                }
            }
            finally {
                reader.releaseLock();
            }
            if (this.activeGenerationId !== generationId) {
                throw new Error('LiteRT generation was cancelled.');
            }
            this.emit({ text: latestText, delta: '', done: true });
            return latestText;
        }
        catch (e) {
            if (this.activeGenerationId !== generationId) {
                throw new Error('LiteRT generation was cancelled.');
            }
            throw e;
        }
    }
    async generateAudioResponseAsync(_audioPath, _prompt) {
        // Mirrors the iOS spike: text-only scope. Audio Scribe on web uses
        // Message multimodal content; wiring follows once text path is verified.
        throw new Error('LiteRT Audio Scribe is not yet wired in the v0.12.0 web spike. Tracked in follow-up.');
    }
    async cancelGenerateResponseAsync() {
        // Invalidate the generation ID first — the reader loop checks this and
        // throws "was cancelled" at the next iteration. Then ask the runtime to
        // stop producing tokens.
        this.activeGenerationId++;
        try {
            this.conversation?.cancel();
        }
        catch {
            // cancel() throws if there's no active generation; safe to ignore.
        }
    }
    async unloadModelAsync() {
        await this.unloadInternal();
    }
    // ---- onToken event-emitter shim ----
    addListener(_eventName, listener) {
        this.listeners.add(listener);
        return {
            remove: () => {
                this.listeners.delete(listener);
            },
        };
    }
    emit(event) {
        for (const l of this.listeners) {
            try {
                l(event);
            }
            catch (e) {
                // Don't let a misbehaving listener kill the generation loop.
                // eslint-disable-next-line no-console
                console.warn('[expo-litert-lm] onToken listener threw:', e);
            }
        }
    }
    // ---- Internals ----
    async unloadInternal() {
        this.activeGenerationId++;
        if (this.conversation) {
            try {
                await this.conversation.delete();
            }
            catch {
                // Best-effort.
            }
            this.conversation = null;
        }
        if (this.engine) {
            try {
                await this.engine.delete();
            }
            catch {
                // Best-effort.
            }
            this.engine = null;
        }
        this.loadConfig = null;
    }
    async requireLitertLm() {
        if (this.litertLm)
            return this.litertLm;
        try {
            // Dynamic import so this module loads cleanly even if @litert-lm/core
            // is not installed — failure surfaces here, in loadModelAsync, with a
            // clear actionable error.
            const mod = (await Promise.resolve().then(() => __importStar(require('@litert-lm/core'))));
            this.litertLm = mod;
            return mod;
        }
        catch (e) {
            throw new Error('expo-litert-lm: web support requires `@litert-lm/core` (>=0.12.0). ' +
                'Install it as a dependency: `npm i @litert-lm/core`. ' +
                `Underlying error: ${e instanceof Error ? e.message : String(e)}`);
        }
    }
}
function extractText(message) {
    if (!message?.content)
        return '';
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
exports.default = expoLitertLmWebModule;
//# sourceMappingURL=ExpoLitertLmModule.web.js.map