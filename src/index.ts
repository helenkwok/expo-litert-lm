/*
 * Copyright (c) 2026 Helen Kwok
 * SPDX-License-Identifier: MIT
 */
import { Platform } from 'react-native';
import {
  LegacyEventEmitter,
  requireNativeModule,
  type EventSubscription,
} from 'expo-modules-core';

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

interface NativeExpoLitertLmModule {
  isAvailableAsync(): Promise<boolean>;
  loadModelAsync(
    modelPath: string,
    maxTokens: number,
    topK: number,
    temperature: number,
    preferredBackend?: LiteRtPreferredBackend
  ): Promise<LiteRtLoadResult>;
  generateResponseAsync(prompt: string): Promise<string>;
  generateAudioResponseAsync(audioPath: string, prompt: string): Promise<string>;
  cancelGenerateResponseAsync(): Promise<void>;
  unloadModelAsync(): Promise<void>;
  sampleMemoryAsync(): Promise<number>;
}

const DEFAULT_MAX_TOKENS = 2048;
const DEFAULT_TOP_K = 40;
const DEFAULT_TEMPERATURE = 0.8;

// Web shim — duck-typed to NativeExpoLitertLmModule + an addListener method.
// See src/ExpoLitertLmModule.web.ts. Imported lazily on Platform.OS === 'web'
// so the WASM-bearing @litert-lm/core peer dep is never pulled into a native
// bundle.
type WebModuleShape = NativeExpoLitertLmModule & {
  addListener: (
    eventName: 'onToken',
    listener: (event: LiteRtTokenEvent) => void
  ) => { remove: () => void };
};

let cachedNative: NativeExpoLitertLmModule | null = null;
let cachedEmitter: LegacyEventEmitter | null = null;
let cachedWeb: WebModuleShape | null = null;

function webModule(): WebModuleShape {
  if (cachedWeb) return cachedWeb;
  // Static import — Metro/webpack resolves the .web.ts variant when
  // Platform.OS === 'web' anyway; using a dynamic import here would not give
  // any extra bundle isolation and would force every caller to be async.
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  const mod = require('./ExpoLitertLmModule.web').default as WebModuleShape;
  cachedWeb = mod;
  return mod;
}

function nativeModule(): NativeExpoLitertLmModule {
  if (Platform.OS === 'web') {
    return webModule();
  }
  if (cachedNative) return cachedNative;
  try {
    const resolved = requireNativeModule<NativeExpoLitertLmModule>('ExpoLitertLm');
    cachedNative = resolved;
    return resolved;
  } catch {
    throw new Error(
      'expo-litert-lm: native module not present in this build. Run `npx expo prebuild` and rebuild your dev client.'
    );
  }
}

function eventEmitter(): {
  addListener: (
    eventName: 'onToken',
    listener: (event: LiteRtTokenEvent) => void
  ) => EventSubscription;
} {
  if (Platform.OS === 'web') {
    return webModule();
  }
  if (cachedEmitter) return cachedEmitter;
  const created = new LegacyEventEmitter(nativeModule() as never);
  cachedEmitter = created;
  return created;
}

/**
 * Whether the device is capable of running LiteRT-LM models.
 * On Android this requires API 31+ (Android 12).
 * On web this requires WebGPU + crossOriginIsolated (SharedArrayBuffer) — see
 * the README "Web setup" section for the COOP/COEP headers your dev/prod
 * server needs.
 */
export async function isLiteRtAvailable(): Promise<boolean> {
  return nativeModule().isAvailableAsync();
}

/**
 * Load a `.litertlm` (LiteRT-LM) or `.task` (MediaPipe Tasks GenAI) model from a local
 * filesystem path. Caller is responsible for resolving the model path (e.g. via
 * `expo-file-system` or a custom download flow).
 */
export async function loadLiteRtModel(
  modelPath: string,
  options: LiteRtLoadOptions = {}
): Promise<LiteRtLoadResult> {
  return nativeModule().loadModelAsync(
    modelPath,
    options.maxTokens ?? DEFAULT_MAX_TOKENS,
    options.topK ?? DEFAULT_TOP_K,
    options.temperature ?? DEFAULT_TEMPERATURE,
    options.preferredBackend
  );
}

/**
 * Run a text-to-text generation against the currently-loaded model.
 * Subscribe to streaming tokens via {@link addLiteRtTokenListener} before calling.
 */
export async function generateLiteRtResponse(prompt: string): Promise<string> {
  return nativeModule().generateResponseAsync(prompt);
}

/**
 * Run an audio-conditioned generation. Android-only as of v0.11.0.
 * Throws on iOS or web.
 */
export async function generateLiteRtAudioResponse(
  audioPath: string,
  prompt: string
): Promise<string> {
  if (Platform.OS !== 'android') {
    throw new Error(
      'expo-litert-lm: audio generation is only available on Android in this release.'
    );
  }
  return nativeModule().generateAudioResponseAsync(audioPath, prompt);
}

/**
 * Cancel an in-flight generation. Safe to call when no generation is active.
 */
export async function cancelLiteRtGeneration(): Promise<void> {
  await nativeModule().cancelGenerateResponseAsync();
}

/**
 * Unload the active model and release engine resources.
 */
export async function unloadLiteRtModel(): Promise<void> {
  await nativeModule().unloadModelAsync();
}

/**
 * Subscribe to streaming token events emitted during {@link generateLiteRtResponse}
 * and {@link generateLiteRtAudioResponse}. Call `.remove()` on the returned
 * subscription to detach.
 */
export function addLiteRtTokenListener(
  listener: (event: LiteRtTokenEvent) => void
): EventSubscription {
  return eventEmitter().addListener('onToken', listener);
}

/**
 * Returns the current process `phys_footprint` in MB. Phase 14 Stage B helper
 * for measuring bridge-included RAM. Source: MemoryProbe
 * (`task_vm_info_data_t.phys_footprint`, the same value iOS uses for jetsam
 * decisions). iOS only — returns 0 on web; not implemented on Android.
 */
export async function sampleMemoryAsync(): Promise<number> {
  if (Platform.OS !== 'ios') return 0;
  return nativeModule().sampleMemoryAsync();
}
