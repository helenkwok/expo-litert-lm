# Changelog

## 0.3.0-rc.0 — 2026-05-19

> Published to npm under the `next` dist-tag. `latest` remains `0.1.2` for
> now — promote `0.3.0-rc.0` → `latest` after a soak period.
>
> Branch: https://github.com/helenkwok/expo-litert-lm/tree/feat/litert-v0.12
> Live web demo: https://expo-litert-lm.pages.dev/

**Headline:** first-party Google LiteRT-LM v0.12.0 across iOS (Metal-GPU
capable) + a new Web platform target (dual runtime — `.litertlm` →
`@litert-lm/core`, `.task` → `@mediapipe/tasks-genai`, mirroring the
native LiteRT-default + MediaPipeFallback architecture). JS-facing API
unchanged from 0.2.0-rc.0 — consumers don't need code changes.

- **iOS: migrated to Google's first-party LiteRT-LM Swift APIs (v0.12.0).**
  Replaces the vendored community `LiteRTLM-Swift` fork + rewrap pipeline.
  Single `CLiteRTLM.xcframework` (Google's release, SHA-pinned to
  `3c2a11ecc8511d1e74efa7ca308dc7130c95223325c33212337ffb0563b79cde`) bundles
  Metal accelerator + TopK Metal sampler + GemmaModelConstraintProvider
  statically. `CFBundleShortVersionString` / `CFBundleVersion` set correctly
  by upstream — the rewrap step is no longer needed.
- **iOS: Metal GPU acceleration available** (was deferred to v1.2 under the
  community fork because of upstream `LiteRTLM-Swift` issues #5 / #7). Set
  `preferredBackend: "gpu"` in `loadModelAsync` to opt in. Pending device
  RAM verification on iPhone SE 3rd gen before recommending as default.
- **Spike scope (iOS):** text-only generation. Vision / audio / multimodal /
  persistent conversation paths are explicitly stubbed in
  `ExpoLitertLmModule.swift` and throw "not yet supported in v0.12.0 spike"
  with a tracking reference. Wiring follows once the text path is verified
  on SE 3rd gen.
- **Web platform support (preview):** opt-in `@litert-lm/core` v0.12.0+ peer
  dependency wires the same JS-facing API (`loadLiteRtModel`,
  `generateLiteRtResponse`, `addLiteRtTokenListener`, `cancelLiteRtGeneration`,
  `unloadLiteRtModel`) onto the Web target via a new
  `src/ExpoLitertLmModule.web.ts` shim. WebGPU + cross-origin-isolation
  required. New `example/web-demo/` provides a zero-dependency Node ESM static
  server with the COOP/COEP headers SharedArrayBuffer needs, plus an HTML
  page that exercises the underlying `@litert-lm/core` package end-to-end via
  a file picker (no fetch / no symlink / no CORS coordination).
  Audio / multimodal stubbed (parallel to iOS spike scope).
- **Dual-runtime web support:** added `@mediapipe/tasks-genai` as a second
  optional peer dep (alongside `@litert-lm/core`) to mirror native's
  LiteRT-LM-default-with-MediaPipe-fallback architecture. Routing is by
  magic-byte sniff on the picked file: `LITERTLM` at offset 0 → `@litert-lm/core`;
  `TFL3` at offset 4 (TFLite flatbuffer) OR `PK\x03\x04` at offset 0 (legacy
  ZIP) → `@mediapipe/tasks-genai`. Each runtime is lazy-imported only when
  its format is requested. Same `loadModelAsync` / `generateResponseAsync`
  / `onToken` event shape on both paths.
- **Web verified status (2026-05-19, Chrome on macOS):**
  - `.litertlm` + CPU works end-to-end on Gemma 3 1B INT4 (557 MB) — peak
    1676 MB, 14.3 tok/s, real per-chunk streaming.
  - `.litertlm` + WebGPU fails on Gemma 3 1B INT4 (compile error in
    `llm_litert_compiled_model_executor.cc`) — the LiteRT-LM web build doesn't
    have WebGPU artifacts for this model variant.
  - `.litertlm` Gemma 4 E2B (2.4 GB) fails on both backends with
    `Array buffer allocation failed` — exceeds 32-bit WASM 4 GB cap.
  - `.task` + GPU and CPU both work on Gemma 3 1B INT4 web (668 MB) at
    ~117 tok/s and ~86 ms TTFT — substantially faster than the LiteRT-LM
    path on the same-tier model.
  - `.task` + both backends work on Gemma 4 E2B web (1.91 GB) at ~58 tok/s —
    the same Gemma 4 E2B model that fails on `.litertlm` runs cleanly on the
    `.task` path. With streaming `ReadableStreamDefaultReader` (added below),
    JS-heap peak is 231 MB GPU / 470 MB CPU — much smaller than the model
    itself because MediaPipe streams chunks straight into WASM. On the
    anti-scam prompt the output drifted into Chinese and Thai mid-paragraph;
    on a simpler prompt (`"hi"`) the same model produced clean monolingual
    English — so that's a prompt-dependent quirk of Gemma 4's multilingual
    training, not a routing or wrapper bug.
  - `.task` Gemma 4 E4B web (2.83 GB) loads (peak 424 MB GPU / 382 MB CPU)
    but output is numeric gibberish — `@mediapipe/tasks-genai` v0.10.27
    doesn't fully support 4B Gemma in this build. File loads, weights stream
    in, inference runs, but tokenizer/decoder fails. Upstream limit.
- **Model bytes streamed to MediaPipe via `ReadableStreamDefaultReader`** —
  not `Uint8Array`. `File.arrayBuffer()` / `Response.arrayBuffer()` choke
  on 2.8 GB+ files in current browsers; the stream reader lets MediaPipe
  pull chunks straight into WASM linear memory without holding the whole
  model in JS heap. Verified: Gemma 4 E2B peak went from 1921 MB
  (arrayBuffer) to 231 MB GPU / 470 MB CPU (stream reader) with identical
  output and decode rate.
- **API port:** `LiteRTLMEngine(modelPath:backend:textOnly:)` →
  `Engine(EngineConfig)`; `engine.load()` async → `engine.initialize()` on
  the actor; `engine.generateStreaming()` → `engine.createConversation()` +
  `conversation.sendMessageStream(Message)`; sampler params moved per-call →
  per-conversation `SamplerConfig`. JS-facing API (`loadModelAsync`,
  `generateResponseAsync`, `onToken` event, cancel/unload) is unchanged.
- **Retired:** `ios/Sources/LiteRTLMSwift/` (community `LiteRTLMEngine` +
  `ModelDownloader`), `ios/BinaryPods/GemmaModelConstraintProviderBinary.podspec`
  (GMCP now linked into `CLiteRTLM`), `ios/BinaryPods/Frameworks/rewrap-manifest.json`,
  `scripts/sync-litertlm-swift.sh` (moved to `.deprecated`).
- **Added:** `scripts/fetch-litert-lm.sh` — pinned-SHA fetch for the v0.12.0
  xcframework from `google-ai-edge/LiteRT-LM` releases. Run before
  `pod install` (xcframework is gitignored, published to npm).
- **Added:** `NOTICE` — Apache 2.0 attribution for Google's vendored Swift
  sources under `ios/Sources/LiteRTLM/` and the `CLiteRTLM.xcframework`
  binary asset.
- **Build verification status:** podspec + Swift port are static-audit clean.
  End-to-end build + one Gemma 3 1B INT4 generation on iPhone SE 3rd gen is
  pending; that gates any npm release.

## 0.2.0 — 2026-05-16

- **Added:** iOS LiteRT-LM text generation via vendored LiteRTLM-Swift / `CLiteRTLM.xcframework`. Validated on iPhone SE 3rd gen with `gemma3-1b-it-int4.litertlm` (Gemma 3 1B INT4). Gemma 4 E2B remains Android-validated only; it was not tested on SE 3rd gen because of memory limits.
- **Added:** `sampleMemoryAsync()` — returns the current process `phys_footprint` in MB for Stage B integration measurement (Phase 14 D-07). iOS only; surfaced via colocated `ios/MemoryProbe.swift` (task_info / TASK_VM_INFO). Stage B example app under `example/` exercises the full Expo + RN + native bridge end-to-end against the rewrapped LiteRTLM-Swift xcframework on SE 3rd gen.
- **Changed:** `scripts/sync-litertlm-swift.sh` rewritten — now fetches rewrapped LiteRTLM-Swift from `helenkwok/LiteRTLM-Swift`'s GitHub Release by tag, verifies SHA-256 against `rewrap-manifest.json`, places artifacts under `ios/BinaryPods/Frameworks/`. Manual sync per Phase 14 D-34. Run `make sync TAG=v<upstream>+rewrap.<n>`.
- **Added:** `ios/BinaryPods/Frameworks/rewrap-manifest.json` — trust anchor (source-controlled JSON, populated by sync script). xcframework binaries remain gitignored.
- **Added:** `ExpoLitertLm.podspec` now reads `vendored_frameworks` and `s.version` from `ios/BinaryPods/Frameworks/rewrap-manifest.json` via Ruby `JSON.parse` at install time. Phase 14 D-31 single source of truth.
- **Added:** Layer A/B/C verification gates (`scripts/verify-consumption.sh`, `make verify`). Layer A = pod install from fresh consumer; Layer B = grep gate for raw xcframework refs; Layer C = manifest-driven podspec consistency.
- **Added:** `.github/workflows/verify-consumption.yml` — CI mirrors fork's three-layer gate on macos-latest.
- **Added:** Expo config plugin (`app.plugin.js`) that injects the split binary pods required for iOS consumers. Verified under `useFrameworks: "static"`; `useFrameworks: "dynamic"` was rejected by CocoaPods because Expo SDK 55 includes static transitive binaries.
- **Fixed:** iOS `loadModelAsync` accepts either a POSIX path or a `file://` URL, including values returned by `expo-document-picker`.
- **Fixed:** Stage B example now records `cancelLatencyMs` when cancellation ends before a final token event arrives.

- **BREAKING:** iOS path migrated from `MediaPipeTasksGenAI` default-dep to vendored `LiteRTLM-Swift` (`CLiteRTLM.xcframework` + `GemmaModelConstraintProvider.xcframework`). Consumers must run `pod install` after upgrade.
- **BREAKING:** `ExpoLitertLm.podspec` no longer carries `static_framework = true` — see CocoaPods issue [#11948](https://github.com/CocoaPods/CocoaPods/issues/11948) + offlineaid Phase 14 CONTEXT D-21. Static linkage of a dylib-containing xcframework crashes the host app at launch.
- **BREAKING:** MediaPipe `.task` support moves to opt-in `MediaPipeFallback` subspec; default install does not include `MediaPipeTasksGenAI` on iOS. Consumers who need it: `pod 'ExpoLitertLm', :subspecs => ['Core', 'MediaPipeFallback']` in their Podfile.
- **Added:** `scripts/sync-litertlm-swift.sh` for manual fork sync. `helenkwok/LiteRTLM-Swift` is the upstream fork pinned by SHA; vendoring happens at sync-time, not at `pod install`-time.
- **Added:** `scripts/rewrap-xcframework.sh` in the fork resolves upstream issue [#6](https://github.com/mylovelycodes/LiteRTLM-Swift/issues/6) offline (Info.plist `CFBundleShortVersionString`, loose-dylib promotion, dSYM emission). TestFlight validation deferred to v1.2 per offlineaid CONTEXT D-25.
- **Synced:** Rewrapped LiteRTLM-Swift `v0.10.2+rewrap.5` (2 xcframeworks, first sha256 `ba2d0c9a6b2a...`).

## 0.1.2 — 2026-05-12

- docs: refine MTP framing — non-Adreno Android blocked by upstream [LiteRT-LM#2211](https://github.com/google-ai-edge/LiteRT-LM/issues/2211) (sampler `dlopen` cross-validated on Pixel 7 / Tensor G2) and [#2227](https://github.com/google-ai-edge/LiteRT-LM/issues/2227) (PowerVR drafter regression). No code changes.

## 0.1.1

- chore: tighten peerDependencies + add Security section.

## 0.1.0

- feat: initial expo-litert-lm — Expo Modules bindings for LiteRT-LM.
