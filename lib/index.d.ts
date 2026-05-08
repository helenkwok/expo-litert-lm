import { type EventSubscription } from 'expo-modules-core';
export type LiteRtPreferredBackend = 'default' | 'gpu' | 'cpu';
export type LiteRtLoadOptions = {
    /** Hard cap on prefill + decode tokens. Default 2048. */
    maxTokens?: number;
    /** Top-K sampling. Default 40. */
    topK?: number;
    /** Sampling temperature. Default 0.8. */
    temperature?: number;
    /** Preferred backend. `'gpu'` is recommended for `.litertlm`; `.task` may use `'default'`. */
    preferredBackend?: LiteRtPreferredBackend;
};
export type LiteRtTokenEvent = {
    /** Cumulative response so far. */
    text: string;
    /** New token(s) since the last event. */
    delta: string;
    /** True on the final event of a generation. */
    done: boolean;
};
export type LiteRtLoadResult = {
    /** Echoes the resolved model path that was loaded. */
    modelPath: string;
    /** Backend the engine actually attached to (`'gpu'`, `'cpu'`, or `'default'`). */
    backend: string;
};
/**
 * Whether the device is capable of running LiteRT-LM models.
 * On Android this requires API 31+ (Android 12). Returns `false` on web.
 */
export declare function isLiteRtAvailable(): Promise<boolean>;
/**
 * Load a `.litertlm` (LiteRT-LM) or `.task` (MediaPipe Tasks GenAI) model from a local
 * filesystem path. Caller is responsible for resolving the model path (e.g. via
 * `expo-file-system` or a custom download flow).
 */
export declare function loadLiteRtModel(modelPath: string, options?: LiteRtLoadOptions): Promise<LiteRtLoadResult>;
/**
 * Run a text-to-text generation against the currently-loaded model.
 * Subscribe to streaming tokens via {@link addLiteRtTokenListener} before calling.
 */
export declare function generateLiteRtResponse(prompt: string): Promise<string>;
/**
 * Run an audio-conditioned generation. Android-only as of v0.11.0.
 * Throws on iOS or web.
 */
export declare function generateLiteRtAudioResponse(audioPath: string, prompt: string): Promise<string>;
/**
 * Cancel an in-flight generation. Safe to call when no generation is active.
 */
export declare function cancelLiteRtGeneration(): Promise<void>;
/**
 * Unload the active model and release engine resources.
 */
export declare function unloadLiteRtModel(): Promise<void>;
/**
 * Subscribe to streaming token events emitted during {@link generateLiteRtResponse}
 * and {@link generateLiteRtAudioResponse}. Call `.remove()` on the returned
 * subscription to detach.
 */
export declare function addLiteRtTokenListener(listener: (event: LiteRtTokenEvent) => void): EventSubscription;
//# sourceMappingURL=index.d.ts.map