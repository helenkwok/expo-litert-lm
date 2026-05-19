# Web smoke test for `@litert-lm/core` v0.12.0

This is a minimal static HTML page that exercises Google's first-party
`@litert-lm/core` web JS package directly — no Expo / React Native involved.
It's the underlying capability that `expo-litert-lm`'s web target (see
`src/ExpoLitertLmModule.web.ts`) wraps, so verifying it works in your browser
also verifies the web path of `expo-litert-lm` will work.

## How to run

1. **Have a `.litertlm` file somewhere on your filesystem.** The page uses a
   file picker — no server-side coordination, no symlinks, no need for the
   file to live next to the HTML. If you've already downloaded
   `gemma-4-E2B-it.litertlm` or `gemma3-1b-it-int4.litertlm` for the native
   build (e.g. in `~/Downloads`), they're ready to use.

   If you don't have one yet: `litert-community/*` repos on Hugging Face are
   **gated** — `curl -L` alone returns a 137-byte "Access denied" HTML
   page. Use the authenticated HF CLI:

   ```bash
   # Install once if you don't have it: pip install -U "huggingface_hub[cli]"
   # Log in once: hf auth login (paste an HF token with read access)

   # Then, into any directory you like:
   hf download litert-community/Gemma-4-E2B-IT gemma-4-E2B-it.litertlm --local-dir ~/Downloads
   # Or the smaller iOS-comparison model:
   hf download litert-community/Gemma3-1B-IT gemma3-1b-it-int4.litertlm --local-dir ~/Downloads
   ```

2. **Serve the page with COOP/COEP headers.** WASM threading needs
   `SharedArrayBuffer`, which requires the page to be *cross-origin
   isolated*. Stock `npx serve` and `python -m http.server` do NOT send the
   needed headers, so use the included tiny Node server (no install, uses
   only Node 18+ stdlib):

   ```bash
   node serve.mjs
   ```

   You should see `Serving on http://localhost:8000/  (COOP/COEP enabled)`.

3. **Open the page in a WebGPU-capable browser:**

   - Chrome 113+ or Edge 113+ on a supported GPU
   - Safari 18+ (macOS 15+ / iOS 18+)
   - Firefox Nightly with `dom.webgpu.enabled` in `about:config`

   <http://localhost:8000/>

4. **Pick the model file with the file input, pick a backend, hit Load &
   Run.** First load takes 5-20 s depending on file size + WASM compile
   time. After that, generation streams into the output box and TTFT /
   tok/s land in the metrics row.

   Note: the file's bytes never traverse the network — `file.stream()`
   delivers them straight from your filesystem into the WASM runtime, same
   origin, no fetch involved.

## What the page measures

- **peak MB** — `performance.memory.usedJSHeapSize` peak during the run.
  Chromium only; Firefox / Safari report 0 (no comparable API).
- **ttft** — wall time from `Engine.create()` completion to the first
  non-empty streaming chunk.
- **tok/s** — `(streaming-chunk count) ÷ (time since first chunk)`. Rough
  proxy for decode speed.

## Why the file picker instead of a URL?

The previous iteration of this page took a model URL and fetched it. That
turned out to be fragile in three ways: (1) Hugging Face gates the
`litert-community/*` repos, so casual `curl`-based downloads landed an HTML
"Access denied" body that the engine misread as a corrupt `.litertlm`;
(2) symlinks into `~/Downloads` failed the server's path-traversal safety
check; (3) direct fetches from HF do not carry the right COOP/COEP/CORS
combination for a cross-origin-isolated page. File picker bypasses all
three — `file.stream()` delivers a `ReadableStream<Uint8Array>` straight
from the user's filesystem to the WASM runtime.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Page says "Not cross-origin isolated" | You bypassed `serve.mjs`. Use it, or set both `Cross-Origin-Opener-Policy: same-origin` and `Cross-Origin-Embedder-Policy: require-corp` on your own server. |
| Page says "No WebGPU" | Your browser does not expose `navigator.gpu`. Try Chrome / Edge 113+ or Safari 18+. |
| Console: "RuntimeError: WebAssembly.Memory(): could not allocate memory" | Your tab does not have enough heap. Close other tabs, restart browser, or try a smaller model. |
| Output box shows red "Invalid magic number" after pick | The picked file is not a real `.litertlm`. Run `xxd <file> \| head -1` — real models start with `4c49 5445 5254 4c4d` (`LITERTLM`). HF "Access denied" pages from un-authed `curl` are a common cause; re-download with the `hf` CLI. |
| Output stops after 1 token | WebGPU adapter crashed. Toggle to CPU backend and re-run. Check the browser's DevTools → Console. |
