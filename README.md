# expo-litert-lm

> Expo Modules bindings for [Google AI Edge LiteRT-LM](https://github.com/google-ai-edge/litert-lm) — on-device Gemma 4 / Gemma 3n inference for Expo apps.

**Status:** Android-first. iOS scaffold exists; full LiteRT-LM iOS support pending. Production-tested in [OfflineAid](https://github.com/helenkwok/offlineaid) (audio + chat).

## What this is

Native bridge for Expo SDK 56+ apps to load and run `.litertlm` and `.task` models from Google's `litert-community` Hugging Face org via the official `litertlm-android:0.11.0` SDK. MIT licensed.

## What this is *not*

- **Not the only option.** [`react-native-litert-lm`](https://github.com/hung-yueh/react-native-litert-lm) by hung-yueh ships **Nitro Modules** bindings with full iOS support and a slightly different API surface. If your app uses Nitro, prefer that. If your app is Expo-first, this package gives you Expo Modules autolinking with no extra build steps.

| | `expo-litert-lm` (this) | `react-native-litert-lm` |
|---|---|---|
| Framework | Expo Modules | Nitro Modules + Expo plugin |
| iOS LiteRT-LM | Scaffold only | Full |
| Android API | 31+ (S) | 26+ |
| MTP / speculative decoding | `ExperimentalFlags.enableSpeculativeDecoding` wired against v0.11.0; on-device `dlopen` blocked by upstream [LiteRT-LM#2211](https://github.com/google-ai-edge/LiteRT-LM/issues/2211) (prebuilt sampler `DT_NEEDED` bug) — architecture verified 2.01× lossless on Mac via mlx-vlm | Not exposed |
| Audio encoder | Production use | iOS limited |
| Multi-runtime | LiteRT-LM `.litertlm` + MediaPipe Tasks GenAI `.task` | LiteRT-LM only |

Both packages exist deliberately. Pick what fits your app.

## Install

```bash
npx expo install expo-litert-lm
```

Or pin a specific version in `package.json`:

```jsonc
"dependencies": {
  "expo-litert-lm": "^0.1.1"
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

- Expo SDK 56+
- Android 12 (API 31) or newer
- A device with GPU support for best performance (e.g. Pixel 7+)
- Models: `.litertlm` (LiteRT-LM) or `.task` (MediaPipe Tasks GenAI)

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
