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
// --- Singleton module ---
class ExpoLitertLmWebModule {
    constructor() {
        // Lazy-loaded peer dep references.
        this.litertLm = null;
        this.mediaPipe = null;
        // Engine state — only one runtime active at a time.
        this.runtime = null;
        this.litertLmEngine = null;
        this.litertLmConversation = null;
        this.mediaPipeLlm = null;
        this.loadConfig = null;
        this.activeGenerationId = 0;
        this.listeners = new Set();
    }
    // ---- NativeExpoLitertLmModule shape ----
    async isAvailableAsync() {
        if (typeof window === 'undefined')
            return false;
        const hasGpu = typeof navigator !== 'undefined' && 'gpu' in navigator;
        const isCOI = typeof globalThis
            .crossOriginIsolated === 'boolean'
            ? globalThis
                .crossOriginIsolated === true
            : false;
        return hasGpu && isCOI;
    }
    async sampleMemoryAsync() {
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
        if (this.runtime &&
            this.loadConfig &&
            this.loadConfig.modelPath === nextConfig.modelPath &&
            this.loadConfig.maxTokens === nextConfig.maxTokens &&
            this.loadConfig.topK === nextConfig.topK &&
            this.loadConfig.temperature === nextConfig.temperature &&
            this.loadConfig.preferredBackend === nextConfig.preferredBackend) {
            return { modelPath, backend: resolvedBackend };
        }
        await this.unloadInternal();
        const runtime = await sniffRuntime(modelPath);
        if (runtime === 'litert-lm') {
            await this.loadLitertLm(modelPath, maxTokens, resolvedBackend);
        }
        else {
            await this.loadMediaPipe(modelPath, maxTokens, topK, temperature, resolvedBackend);
        }
        this.runtime = runtime;
        this.loadConfig = nextConfig;
        return { modelPath, backend: resolvedBackend };
    }
    async generateResponseAsync(prompt) {
        if (!this.runtime) {
            throw new Error('No LiteRT model loaded.');
        }
        const generationId = ++this.activeGenerationId;
        if (this.runtime === 'litert-lm') {
            return this.generateLitertLm(prompt, generationId);
        }
        return this.generateMediaPipe(prompt, generationId);
    }
    async generateAudioResponseAsync(_audioPath, _prompt) {
        throw new Error('LiteRT Audio Scribe is not yet wired in the v0.12.0 web spike. Tracked in follow-up.');
    }
    async cancelGenerateResponseAsync() {
        this.activeGenerationId++;
        if (this.runtime === 'litert-lm') {
            try {
                this.litertLmConversation?.cancel();
            }
            catch {
                // ignore — cancel() throws if there's no active generation
            }
        }
        // @mediapipe LlmInference does not expose a runtime cancel — the gate via
        // activeGenerationId in the progressListener breaks the await loop.
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
                // eslint-disable-next-line no-console
                console.warn('[expo-litert-lm] onToken listener threw:', e);
            }
        }
    }
    // ---- LiteRT-LM runtime ----
    async loadLitertLm(modelPath, maxTokens, preferredBackend) {
        const litertLm = await this.requireLitertLm();
        const backend = preferredBackend === 'cpu' ? litertLm.Backend.CPU : litertLm.Backend.GPU;
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
    async generateLitertLm(prompt, generationId) {
        const conversation = this.litertLmConversation;
        if (!conversation)
            throw new Error('No LiteRT model loaded.');
        let latestText = '';
        try {
            const stream = conversation.sendMessageStreaming(prompt);
            const reader = stream.getReader();
            try {
                while (true) {
                    const { value: chunk, done } = await reader.read();
                    if (done)
                        break;
                    if (this.activeGenerationId !== generationId) {
                        throw new Error('LiteRT generation was cancelled.');
                    }
                    const delta = chunk?.content
                        ? extractText(chunk)
                        : '';
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
    // ---- MediaPipe Tasks GenAI runtime ----
    async loadMediaPipe(modelPath, maxTokens, topK, temperature, preferredBackend) {
        const mp = await this.requireMediaPipe();
        const wasmFileset = await mp.FilesetResolver.forGenAiTasks(
        // Default: jsDelivr CDN. Consumers can override by re-injecting
        // FilesetResolver with their own basePath before calling loadModelAsync,
        // but for the spike's MVP shape we accept this default.
        'https://cdn.jsdelivr.net/npm/@mediapipe/tasks-genai/wasm');
        // MediaPipe accepts either a Uint8Array OR a ReadableStreamDefaultReader
        // for `modelAssetBuffer`. We use a stream reader so that large models
        // (multi-GB) are pulled in chunks instead of materialising the whole file
        // as a single JS-heap allocation — `File.arrayBuffer()` and
        // `Response.arrayBuffer()` choke on ~2.8 GB+ files in current browsers.
        const response = await fetch(modelPath);
        if (!response.ok) {
            throw new Error(`Failed to fetch .task model from ${modelPath}: HTTP ${response.status}`);
        }
        if (!response.body) {
            throw new Error(`Fetch response for ${modelPath} has no body stream — cannot load model.`);
        }
        const reader = response.body.getReader();
        const delegate = preferredBackend === 'cpu' ? 'CPU' : 'GPU';
        const llm = await mp.LlmInference.createFromOptions(wasmFileset, {
            baseOptions: { modelAssetBuffer: reader, delegate },
            maxTokens: maxTokens > 0 ? maxTokens : 512,
            topK: topK > 0 ? topK : 40,
            temperature: temperature >= 0 ? temperature : 0.7,
        });
        this.mediaPipeLlm = llm;
    }
    async generateMediaPipe(prompt, generationId) {
        const llm = this.mediaPipeLlm;
        if (!llm)
            throw new Error('No LiteRT model loaded.');
        // `generateResponse(prompt, listener)` returns Promise<string> with the
        // full response. The listener is called for streaming chunks when
        // streaming is supported by this MediaPipe build/model. Some builds only
        // fire the listener once with (fullText, done=true). We capture both: the
        // listener feeds onToken deltas progressively, AND we await the returned
        // Promise so the full text is the source of truth.
        let latestText = '';
        let sawStreamingChunk = false;
        const fullText = await llm.generateResponse(prompt, (partialResult, _done) => {
            if (this.activeGenerationId !== generationId)
                return;
            if (partialResult && partialResult.length > 0) {
                sawStreamingChunk = true;
                latestText += partialResult;
                this.emit({
                    text: latestText,
                    delta: partialResult,
                    done: false,
                });
            }
        });
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
    async requireLitertLm() {
        if (this.litertLm)
            return this.litertLm;
        try {
            const mod = (await Promise.resolve().then(() => __importStar(require('@litert-lm/core'))));
            this.litertLm = mod;
            return mod;
        }
        catch (e) {
            throw new Error('expo-litert-lm: web .litertlm support requires `@litert-lm/core` (>=0.12.0). ' +
                'Install it: `npm i @litert-lm/core`. ' +
                `Underlying error: ${e instanceof Error ? e.message : String(e)}`);
        }
    }
    async requireMediaPipe() {
        if (this.mediaPipe)
            return this.mediaPipe;
        try {
            const mod = (await Promise.resolve().then(() => __importStar(require('@mediapipe/tasks-genai'))));
            this.mediaPipe = mod;
            return mod;
        }
        catch (e) {
            throw new Error('expo-litert-lm: web .task support requires `@mediapipe/tasks-genai` (>=0.10.27). ' +
                'Install it: `npm i @mediapipe/tasks-genai`. ' +
                `Underlying error: ${e instanceof Error ? e.message : String(e)}`);
        }
    }
    // ---- Internals ----
    async unloadInternal() {
        this.activeGenerationId++;
        if (this.litertLmConversation) {
            try {
                await this.litertLmConversation.delete();
            }
            catch {
                // best-effort
            }
            this.litertLmConversation = null;
        }
        if (this.litertLmEngine) {
            try {
                await this.litertLmEngine.delete();
            }
            catch {
                // best-effort
            }
            this.litertLmEngine = null;
        }
        if (this.mediaPipeLlm) {
            try {
                this.mediaPipeLlm.close();
            }
            catch {
                // best-effort
            }
            this.mediaPipeLlm = null;
        }
        this.runtime = null;
        this.loadConfig = null;
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
async function sniffRuntime(modelPath) {
    let head;
    try {
        const resp = await fetch(modelPath, { headers: { Range: 'bytes=0-15' } });
        if (!resp.ok && resp.status !== 206) {
            throw new Error(`HTTP ${resp.status} fetching model header`);
        }
        head = new Uint8Array(await resp.arrayBuffer());
    }
    catch (e) {
        throw new Error(`expo-litert-lm: could not read model header from ${modelPath}: ${e instanceof Error ? e.message : String(e)}`);
    }
    // LITERTLM at offset 0
    if (head.length >= 8 &&
        head[0] === 0x4c && head[1] === 0x49 && head[2] === 0x54 && head[3] === 0x45 &&
        head[4] === 0x52 && head[5] === 0x54 && head[6] === 0x4c && head[7] === 0x4d) {
        return 'litert-lm';
    }
    // TFL3 at offset 4 — raw TFLite flatbuffer container (recent MediaPipe .task)
    if (head.length >= 8 &&
        head[4] === 0x54 && head[5] === 0x46 && head[6] === 0x4c && head[7] === 0x33) {
        return 'mediapipe';
    }
    // PK\x03\x04 at offset 0 — ZIP archive (legacy MediaPipe .task)
    if (head.length >= 4 &&
        head[0] === 0x50 && head[1] === 0x4b && head[2] === 0x03 && head[3] === 0x04) {
        return 'mediapipe';
    }
    throw new Error(`expo-litert-lm: model at ${modelPath} is not a recognised format. ` +
        `Expected LITERTLM (.litertlm), TFL3 at offset 4 (.task), or PK ZIP (.task legacy). ` +
        `First 16 bytes: ${Array.from(head.slice(0, 16))
            .map((b) => b.toString(16).padStart(2, '0'))
            .join(' ')}`);
}
const expoLitertLmWebModule = new ExpoLitertLmWebModule();
exports.default = expoLitertLmWebModule;
//# sourceMappingURL=ExpoLitertLmModule.web.js.map