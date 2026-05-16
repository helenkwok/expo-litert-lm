# expo-litert-lm Stage B example

Phase 14 Stage B validation app per OfflineAid CONTEXT D-02 / RESEARCH.md Q10.
Exercises the full Expo + React Native + ExpoLitertLm bridge end-to-end on a
physical SE 3rd-gen device and re-measures `phys_footprint` from JS.

**Stage A (14-06)** measured engine-only memory (raw Swift + LiteRTLM bridge).
**Stage B (this app)** measures bridge-included memory through the JS surface.
The Stage A↔B delta localizes the JS-bridge + RN overhead (D-03 diagnostic).

## Prereqs

- Paired SE 3rd gen on iOS 26.5 (UDID 00008110-000610C0118B801E).
- Paid Apple Developer team `6ZUA894YBV` (free team strips
  `increased-memory-limit` per PITFALLS.md #11).
- `gemma3-1b-it-int4.litertlm` (557 MB) copied to the device under Files →
  On My iPhone → expolitertlmexample (works once UIFileSharingEnabled mounts
  the app's Documents directory). Source: Hugging Face gated model;
  HF_TOKEN required to fetch (keychain-stored, see project memory).

## Deploy

```sh
cd repositories/expo-litert-lm/example
npm install
npx expo prebuild --platform ios --clean
cd ios && pod install && cd ..
npx expo run:ios --device   # pick SE3 from device list
```

The first launch on the device may take ~60 s — first build links the
LiteRTLM-rewrapped.xcframework via the `file:..` link to the parent module.

## Spike harness

1. Tap **Pick .litertlm model** → select gemma3-1b-it-int4.litertlm.
2. Tap **Run spike** → streams the same 256-token prefill prompt from Stage A.
   A 250 ms `sampleMemoryAsync` poll updates the on-screen MB and peakMb labels.
3. Run finishes after ~50 s; final peakMb is the gate value.
4. Re-tap **Run spike**, then **Cancel** mid-stream — verifies IOSC-03
   cancellation latency from the JS surface. The app records latency even
   when native cancellation ends before a final token event is emitted.
5. Retrieve `rss-stageB-*.ndjson` from Xcode → Devices → expolitertlmexample
   → Download Container → AppData/Documents.

## What's intentionally absent

- No MediaPipe Tasks GenAI link path. Default `pod install` MUST NOT pull
  `MediaPipeTasksGenAI` into Podfile.lock (CONTEXT D-22).
- No audio / vision surface. Phase 14 spike scope is chat-only (D-02).
- No model download from JS. Files-app-copy keeps the harness deterministic
  and the example free of HF auth code.

## Notes

- The picker passes its raw `file://` URI into `loadLiteRtModel`; the native
  iOS module accepts both picker URIs and POSIX paths.
