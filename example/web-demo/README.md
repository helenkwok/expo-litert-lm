# Web smoke test for `@litert-lm/core` v0.12.0

This is a minimal static HTML page that exercises Google's first-party
`@litert-lm/core` web JS package directly — no Expo / React Native involved.
It's the underlying capability that `expo-litert-lm`'s web target (see
`src/ExpoLitertLmModule.web.ts`) wraps, so verifying it works in your browser
also verifies the web path of `expo-litert-lm` will work.

## How to run

1. **Drop a model in this directory.** The page defaults to a relative URL of
   `./gemma3-1b-it-int4.litertlm`:

   ```bash
   # Download the 584 MB INT4 model (Apache 2.0 + Gemma terms, ~1 min on broadband):
   curl -L -o gemma3-1b-it-int4.litertlm \
     https://huggingface.co/litert-community/Gemma3-1B-IT/resolve/main/gemma3-1b-it-int4.litertlm
   ```

2. **Serve with COOP/COEP headers.** WASM threading needs `SharedArrayBuffer`,
   which requires the page to be *cross-origin isolated*. Stock `npx
   serve` and `python -m http.server` do NOT send the needed headers, so use
   the included tiny Node server (no install, uses only Node 18+ stdlib):

   ```bash
   node serve.mjs
   ```

   You should see `Serving on http://localhost:8000/  (COOP/COEP enabled)`.

3. **Open the page in a WebGPU-capable browser:**

   - Chrome 113+ or Edge 113+ on a supported GPU
   - Safari 18+ (macOS 15+ / iOS 18+)
   - Firefox Nightly with `dom.webgpu.enabled` in `about:config`

   <http://localhost:8000/>

4. **Pick a backend, hit Load & Run.** First load takes 5-20 s depending on
   network + WASM compile time. After that, generation streams into the
   output box and TTFT / tok/s land in the metrics row.

## What the page measures

- **peak MB** — `performance.memory.usedJSHeapSize` peak during the run.
  Chromium only; Firefox / Safari report 0 (no comparable API).
- **ttft** — wall time from `Engine.create()` completion to the first
  non-empty streaming chunk.
- **tok/s** — `(streaming-chunk count) ÷ (time since first chunk)`. Rough
  proxy for decode speed.

## Why direct-from-HF loading does not work

Hugging Face serves the file but does not send the right COOP/COEP/CORS
combination for a cross-origin-isolated page to consume it. You have to
download to a local directory once and serve from there, or run a proxy that
forwards HF responses with the right headers.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Page says "Not cross-origin isolated" | You bypassed `serve.mjs`. Use it, or set both `Cross-Origin-Opener-Policy: same-origin` and `Cross-Origin-Embedder-Policy: require-corp` on your own server. |
| Page says "No WebGPU" | Your browser does not expose `navigator.gpu`. Try Chrome / Edge 113+ or Safari 18+. |
| Console: "RuntimeError: WebAssembly.Memory(): could not allocate memory" | Your tab does not have enough heap. Close other tabs, restart browser, or try a smaller model. |
| Model 404s | Filename mismatch. The page defaults to `./gemma3-1b-it-int4.litertlm`; edit the URL field if your file is named differently. |
| Output stops after 1 token | WebGPU adapter crashed. Toggle to CPU backend and re-run. Check the browser's DevTools → Console. |
