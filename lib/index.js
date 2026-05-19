"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.isLiteRtAvailable = isLiteRtAvailable;
exports.loadLiteRtModel = loadLiteRtModel;
exports.generateLiteRtResponse = generateLiteRtResponse;
exports.generateLiteRtAudioResponse = generateLiteRtAudioResponse;
exports.cancelLiteRtGeneration = cancelLiteRtGeneration;
exports.unloadLiteRtModel = unloadLiteRtModel;
exports.addLiteRtTokenListener = addLiteRtTokenListener;
exports.sampleMemoryAsync = sampleMemoryAsync;
/*
 * Copyright (c) 2026 Helen Kwok
 * SPDX-License-Identifier: MIT
 */
const react_native_1 = require("react-native");
const expo_modules_core_1 = require("expo-modules-core");
const DEFAULT_MAX_TOKENS = 2048;
const DEFAULT_TOP_K = 40;
const DEFAULT_TEMPERATURE = 0.8;
let cachedNative = null;
let cachedEmitter = null;
let cachedWeb = null;
function webModule() {
    if (cachedWeb)
        return cachedWeb;
    // Static import — Metro/webpack resolves the .web.ts variant when
    // Platform.OS === 'web' anyway; using a dynamic import here would not give
    // any extra bundle isolation and would force every caller to be async.
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    const mod = require('./ExpoLitertLmModule.web').default;
    cachedWeb = mod;
    return mod;
}
function nativeModule() {
    if (react_native_1.Platform.OS === 'web') {
        return webModule();
    }
    if (cachedNative)
        return cachedNative;
    try {
        const resolved = (0, expo_modules_core_1.requireNativeModule)('ExpoLitertLm');
        cachedNative = resolved;
        return resolved;
    }
    catch {
        throw new Error('expo-litert-lm: native module not present in this build. Run `npx expo prebuild` and rebuild your dev client.');
    }
}
function eventEmitter() {
    if (react_native_1.Platform.OS === 'web') {
        return webModule();
    }
    if (cachedEmitter)
        return cachedEmitter;
    const created = new expo_modules_core_1.LegacyEventEmitter(nativeModule());
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
async function isLiteRtAvailable() {
    return nativeModule().isAvailableAsync();
}
/**
 * Load a `.litertlm` (LiteRT-LM) or `.task` (MediaPipe Tasks GenAI) model from a local
 * filesystem path. Caller is responsible for resolving the model path (e.g. via
 * `expo-file-system` or a custom download flow).
 */
async function loadLiteRtModel(modelPath, options = {}) {
    return nativeModule().loadModelAsync(modelPath, options.maxTokens ?? DEFAULT_MAX_TOKENS, options.topK ?? DEFAULT_TOP_K, options.temperature ?? DEFAULT_TEMPERATURE, options.preferredBackend);
}
/**
 * Run a text-to-text generation against the currently-loaded model.
 * Subscribe to streaming tokens via {@link addLiteRtTokenListener} before calling.
 */
async function generateLiteRtResponse(prompt) {
    return nativeModule().generateResponseAsync(prompt);
}
/**
 * Run an audio-conditioned generation. Android-only as of v0.11.0.
 * Throws on iOS or web.
 */
async function generateLiteRtAudioResponse(audioPath, prompt) {
    if (react_native_1.Platform.OS !== 'android') {
        throw new Error('expo-litert-lm: audio generation is only available on Android in this release.');
    }
    return nativeModule().generateAudioResponseAsync(audioPath, prompt);
}
/**
 * Cancel an in-flight generation. Safe to call when no generation is active.
 */
async function cancelLiteRtGeneration() {
    await nativeModule().cancelGenerateResponseAsync();
}
/**
 * Unload the active model and release engine resources.
 */
async function unloadLiteRtModel() {
    await nativeModule().unloadModelAsync();
}
/**
 * Subscribe to streaming token events emitted during {@link generateLiteRtResponse}
 * and {@link generateLiteRtAudioResponse}. Call `.remove()` on the returned
 * subscription to detach.
 */
function addLiteRtTokenListener(listener) {
    return eventEmitter().addListener('onToken', listener);
}
/**
 * Returns the current process `phys_footprint` in MB. Phase 14 Stage B helper
 * for measuring bridge-included RAM. Source: MemoryProbe
 * (`task_vm_info_data_t.phys_footprint`, the same value iOS uses for jetsam
 * decisions). iOS only — returns 0 on web; not implemented on Android.
 */
async function sampleMemoryAsync() {
    if (react_native_1.Platform.OS !== 'ios')
        return 0;
    return nativeModule().sampleMemoryAsync();
}
//# sourceMappingURL=index.js.map