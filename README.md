# expo-litert-lm

[![npm version](https://img.shields.io/npm/v/expo-litert-lm.svg)](https://www.npmjs.com/package/expo-litert-lm)
[![npm downloads](https://img.shields.io/npm/dm/expo-litert-lm.svg)](https://www.npmjs.com/package/expo-litert-lm)
[![license](https://img.shields.io/npm/l/expo-litert-lm.svg)](https://github.com/helenkwok/expo-litert-lm/blob/main/LICENSE)

> Expo Modules bindings for [Google AI Edge LiteRT-LM](https://github.com/google-ai-edge/litert-lm) - on-device Gemma inference for Expo apps. **[View on npm →](https://www.npmjs.com/package/expo-litert-lm)**

**Status:** Android production-tested in [OfflineAid](https://github.com/helenkwok/offlineaid) with Gemma 4 E2B chat + audio. iOS LiteRT-LM text generation is validated on iPhone SE 3rd gen with `gemma3-1b-it-int4.litertlm` (Gemma 3 1B INT4); iOS audio/vision remain planned.

## What this is

Native bridge for Expo SDK 55+ apps to load and run `.litertlm` and `.task` models from Google's `litert-community` Hugging Face org.

- Android uses Google's official `litertlm-android:0.11.0` SDK plus MediaPipe Tasks GenAI.
- iOS uses vendored LiteRTLM-Swift wrapping the LiteRT-LM C API (`CLiteRTLM.xcframework` + `GemmaModelConstraintProvider.xcframework`, rewrapped from LiteRTLM-Swift `v0.10.2+rewrap.5`).
- iOS `.task` support is available only through the opt-in `MediaPipeFallback` CocoaPods subspec; the default iOS install is LiteRT-LM only.
- **Web (preview, on `feat/litert-v0.12` branch)** — dual runtime: `.litertlm` files route to Google's first-party [`@litert-lm/core`](https://www.npmjs.com/package/@litert-lm/core) v0.12.0+, `.task` files route to [`@mediapipe/tasks-genai`](https://www.npmjs.com/package/@mediapipe/tasks-genai) — mirroring the native LiteRT-default + MediaPipeFallback architecture. Both are opt-in peer dependencies. JS-facing API is identical to the native shape — same `loadLiteRtModel` / `generateLiteRtResponse` / `addLiteRtTokenListener` work on web. Requires WebGPU + a cross-origin-isolated context. **Live demo: [expo-litert-lm.pages.dev](https://expo-litert-lm.pages.dev/)** (Cloudflare Pages, free tier, no Workers). See [`example/web-demo/`](./example/web-demo/) and the v0.12.0 entry in [`CHANGELOG.md`](./CHANGELOG.md).

MIT licensed.

## What this is *not*

- **Not the only option.** [`react-native-litert-lm`](https://github.com/hung-yueh/react-native-litert-lm) by hung-yueh ships **Nitro Modules** bindings with full iOS support and a slightly different API surface. If your app uses Nitro, prefer that. If your app is Expo-first, this package gives you Expo Modules autolinking with no extra build steps.

| | `expo-litert-lm` (this) | `react-native-litert-lm` |
|---|---|---|
| Framework | Expo Modules | Nitro Modules + Expo plugin |
| iOS LiteRT-LM | Text/chat validated on iPhone SE 3rd gen with Gemma 3 1B INT4; audio/vision deferred | Full |
| Android API | 31+ (S) | 26+ |
| MTP / speculative decoding | `ExperimentalFlags.enableSpeculativeDecoding` wired against v0.11.0; blocked upstream on non-Adreno Android by [LiteRT-LM#2211](https://github.com/google-ai-edge/LiteRT-LM/issues/2211) (sampler `dlopen` fails on Tensor G2/G6 — cross-validated 2026-05-12) and [#2227](https://github.com/google-ai-edge/LiteRT-LM/issues/2227) (drafter regression on PowerVR even with sampler loaded). Architecture verified 2.01× lossless on Mac via mlx-vlm. | Not exposed |
| Audio encoder | Android production use; iOS throws a clear not-yet-available error | iOS limited |
| Multi-runtime | LiteRT-LM `.litertlm` + MediaPipe Tasks GenAI `.task` | LiteRT-LM only |

Both packages exist deliberately. Pick what fits your app.

## Development Toolchain

This module's iOS path requires **Xcode 16.4+** and **CocoaPods 1.10+**. The consumer app `offlineaid` pins specific versions via `.tool-versions` at its repo root (Phase 14 lockdown). If you're integrating `expo-litert-lm` into a different consumer, mirror that pin or install `asdf` + the [`klaaspieter/asdf-xcode`](https://github.com/klaaspieter/asdf-xcode) plugin and run `asdf install` against an equivalent `.tool-versions`. See `repositories/offlineaid/.tool-versions` for the canonical values.

## Install

```bash
npx expo install expo-litert-lm
```

Or pin a specific version in `package.json`:

```jsonc
"dependencies": {
  "expo-litert-lm": "^0.2.0"
}
```

Or as a local file dependency during development:

```jsonc
// package.json
"dependencies": {
  "expo-litert-lm": "file:../expo-litert-lm"
}
```

Run `npx expo prebuild` after install so the native module gets autolinked.

## Use

```typescript
import {
  loadLiteRtModel,
  unloadLiteRtModel,
  generateLiteRtResponse,
  isLiteRtAvailable,
} from 'expo-litert-lm';

if (await isLiteRtAvailable()) {
  await loadLiteRtModel(
    '/data/user/0/.../litert-models/gemma-4-E2B-it.litertlm',
    {
      maxTokens: 2048,
      topK: 40,
      temperature: 0.8,
      preferredBackend: 'gpu', // or 'cpu'
    },
  );

  const result = await generateLiteRtResponse('Tell me about offline AI.');
  console.log(result);

  await unloadLiteRtModel();
}
```

## Requirements

- Expo SDK 55+
- Android 12 (API 31) or newer
- iOS 17.0 or newer for the LiteRT-LM path
- Android: a device with GPU support for best performance (e.g. Pixel 7+)
- iOS: iPhone SE 3rd gen / A15 is the validated floor for Gemma 3 1B INT4. Gemma 4 E2B has not been validated on SE 3rd gen due to memory limits.
- Models: `.litertlm` (LiteRT-LM) or `.task` (MediaPipe Tasks GenAI; Android by default, iOS only with `MediaPipeFallback`)

## iOS Notes

`v0.2.0` adds the iOS LiteRT-LM path and ships the rewrapped xcframeworks inside the npm tarball. The included Expo config plugin injects the two binary pods that CocoaPods needs:

```jsonc
{
  "expo": {
    "plugins": ["expo-litert-lm"]
  }
}
```

The plugin is compatible with Expo's `useFrameworks: "static"` consumer apps. A `useFrameworks: "dynamic"` diagnostic was run on the example app and CocoaPods rejected it because Expo SDK 55 has static transitive binaries (`ExpoModulesCore` / `ExpoModulesJSI`), so the split-binary pod path is intentional.

The iOS loader accepts both POSIX paths and `file://` URLs, including values returned by `expo-document-picker`.

The SE 3rd gen validation used the default CPU backend. iOS Metal/GPU acceleration is not claimed in this release.

## Security

This package ships **zero JavaScript runtime dependencies** (`"dependencies": {}` in `package.json`). The Kotlin (Android) and Swift (iOS) sources don't pull anything beyond `litertlm-android` and standard Expo Modules core.

If a vulnerability scanner (Snyk, npm audit, etc.) flags issues against this package, they're inherited from your app's **Expo build-tooling chain** — not runtime code we ship. Common examples as of 2026-05-10:

| Flagged transitive | Lives in | Affects |
|---|---|---|
| `uuid@7` | `expo` → `@expo/config-plugins` → `xcode` | iOS plugin generation (build time) |
| `postcss@8.4.x` | `expo` → `@expo/metro-config` | CSS handling for web builds |
| `inflight@1.x` | `expo` → `@expo/cli` | Dev-server tooling |

These are dev/build-tooling concerns inherited via the `expo` peer dep and will appear in any Expo project regardless of whether this package is installed. They cannot be remediated by us — only by upstream Expo.

`peerDependencies` are pinned to `expo >=55.0.0`, `expo-modules-core >=2.0.0`, `react >=18.0.0`, `react-native >=0.74.0` (the floor we've actually tested against) so scanners resolve to the consumer's real Expo version rather than guessing.

If you find a vulnerability in code this package actually ships (Kotlin / Swift / TS in `src/` and `lib/`), please open an issue.

## License

MIT — see [LICENSE](./LICENSE).

## Acknowledgements

- Google AI Edge for [LiteRT-LM](https://github.com/google-ai-edge/litert-lm) and the [`litert-community`](https://huggingface.co/litert-community) HF org.
- hung-yueh for [`react-native-litert-lm`](https://github.com/hung-yueh/react-native-litert-lm) — the prior art that proved community LiteRT-LM bindings could exist.
