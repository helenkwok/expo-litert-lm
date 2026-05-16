# Changelog

## 0.2.0-dev.1 — Phase 14 (in progress, 2026-05-15)

- **Changed:** `scripts/sync-litertlm-swift.sh` rewritten — now fetches rewrapped LiteRTLM-Swift from `helenkwok/LiteRTLM-Swift`'s GitHub Release by tag, verifies SHA-256 against `rewrap-manifest.json`, places artifacts under `ios/Frameworks/`. Manual sync per Phase 14 D-34. Run `make sync TAG=v<upstream>+rewrap.<n>`.
- **Added:** `ios/Frameworks/rewrap-manifest.json` — trust anchor (source-controlled JSON, populated by sync script). xcframework binaries remain gitignored.
- **Added:** `ExpoLitertLm.podspec` now reads `vendored_frameworks` and `s.version` from `ios/Frameworks/rewrap-manifest.json` via Ruby `JSON.parse` at install time. Phase 14 D-31 single source of truth.
- **Added:** Layer A/B/C verification gates (`scripts/verify-consumption.sh`, `make verify`). Layer A = pod install from fresh consumer; Layer B = grep gate for raw xcframework refs; Layer C = manifest-driven podspec consistency.
- **Added:** `.github/workflows/verify-consumption.yml` — CI mirrors fork's three-layer gate on macos-latest.

- **BREAKING:** iOS path migrated from `MediaPipeTasksGenAI` default-dep to vendored `LiteRTLM-Swift` (`CLiteRTLM.xcframework` + `GemmaModelConstraintProvider.xcframework`). Consumers must run `pod install` after upgrade.
- **BREAKING:** `ExpoLitertLm.podspec` no longer carries `static_framework = true` — see CocoaPods issue [#11948](https://github.com/CocoaPods/CocoaPods/issues/11948) + offlineaid Phase 14 CONTEXT D-21. Static linkage of a dylib-containing xcframework crashes the host app at launch.
- **BREAKING:** MediaPipe `.task` support moves to opt-in `MediaPipeFallback` subspec; default install does not include `MediaPipeTasksGenAI` on iOS. Consumers who need it: `pod 'ExpoLitertLm', :subspecs => ['Core', 'MediaPipeFallback']` in their Podfile.
- Added: `scripts/sync-litertlm-swift.sh` for manual fork sync. `helenkwok/LiteRTLM-Swift` is the upstream fork pinned by SHA; vendoring happens at sync-time, not at `pod install`-time.
- Added: `scripts/rewrap-xcframework.sh` in the fork resolves upstream issue [#6](https://github.com/mylovelycodes/LiteRTLM-Swift/issues/6) offline (Info.plist `CFBundleShortVersionString`, loose-dylib promotion, dSYM emission). TestFlight validation deferred to v1.2 per offlineaid CONTEXT D-25.

## 0.1.2 — 2026-05-12

- docs: refine MTP framing — non-Adreno Android blocked by upstream [LiteRT-LM#2211](https://github.com/google-ai-edge/LiteRT-LM/issues/2211) (sampler `dlopen` cross-validated on Pixel 7 / Tensor G2) and [#2227](https://github.com/google-ai-edge/LiteRT-LM/issues/2227) (PowerVR drafter regression). No code changes.

## 0.1.1

- chore: tighten peerDependencies + add Security section.

## 0.1.0

- feat: initial expo-litert-lm — Expo Modules bindings for LiteRT-LM.
2026-05-16 — synced rewrapped LiteRTLM-Swift v0.10.2+rewrap.1 (2 xcframeworks, first sha256: 10565a593a70...)
