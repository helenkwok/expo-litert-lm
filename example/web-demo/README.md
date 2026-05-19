# Web smoke test for `expo-litert-lm`

This static HTML page exercises both web runtimes that `expo-litert-lm`'s web
target routes between (see `src/ExpoLitertLmModule.web.ts`):

| File extension | Runtime | Native parity |
|---|---|---|
| `.litertlm` | [`@litert-lm/core`](https://www.npmjs.com/package/@litert-lm/core) (WebGPU/CPU) | iOS Core / Android default |
| `.task` | [`@mediapipe/tasks-genai`](https://www.npmjs.com/package/@mediapipe/tasks-genai) (WebGPU/CPU) | iOS MediaPipeFallback subspec / Android MediaPipe path |

Routing is by **magic-byte sniff** on the first 8 bytes of the picked file
(`LITERTLM` ASCII → LiteRT-LM, `PK\x03\x04` ZIP magic → MediaPipe Tasks GenAI
.task archives). The page mirrors that sniff inline so it can run without a
bundler; the wrapper module uses the same logic.

## How to run

1. **Have a `.litertlm` or `.task` file somewhere on your filesystem.** The
   page uses a file picker — no server-side coordination, no symlinks, no
   need for the file to live next to the HTML.

   `litert-community/*` repos on Hugging Face are **gated** — `curl -L`
   alone returns a 137-byte "Access denied" HTML page. Use the
   authenticated HF CLI:

   ```bash
   # Install once if you don't have it: pip install -U "huggingface_hub[cli]"
   # Log in once: hf auth login (paste an HF token with read access)

   # LiteRT-LM path (.litertlm):
   hf download litert-community/Gemma3-1B-IT gemma3-1b-it-int4.litertlm --local-dir ~/Downloads
   # MediaPipe Tasks GenAI path (.task — web-optimized variant):
   hf download litert-community/Gemma3-1B-IT gemma3-1b-it-int4-web.task --local-dir ~/Downloads
   # Or, for a larger desktop test:
   hf download litert-community/gemma-4-E2B-it-litert-lm gemma-4-E2B-it-web.task --local-dir ~/Downloads
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

## Verified status (2026-05-19 — Chrome on macOS, anti-scam prompt)

`.task` path uses MediaPipe's streaming `ReadableStreamDefaultReader` rather
than `File.arrayBuffer()`, so the JS-heap peak stays close to model **header
overhead** instead of full model size.

| Format | Model | Backend | Peak | TTFT | Decode | Result |
|---|---|---|---|---|---|---|
| `.litertlm` | Gemma 3 1B INT4 (557 MB) | CPU | 1676 MB | 33.2 s | 57 chars/s (≈ 14.3 tok/s) | ✅ Real streaming (467 chunks) |
| `.litertlm` | Gemma 3 1B INT4 (557 MB) | WebGPU | 562 MB | — | — | ❌ Compile error in `llm_litert_compiled_model_executor.cc:1928` — model lacks WebGPU artifacts |
| `.litertlm` | Gemma 4 E2B (2.4 GB) | both | 2455 MB | — | — | ❌ `Array buffer allocation failed` — exceeds 32-bit WASM linear memory cap |
| `.task` | Gemma 3 1B INT4 web (668 MB) | GPU | **301 MB** | 95 ms | 468 chars/s (≈ 116.9 tok/s) | ✅✅ 54 chunks |
| `.task` | Gemma 3 1B INT4 web (668 MB) | CPU | ~470 MB | 92 ms | 469 chars/s (≈ 117.2 tok/s) | ✅✅ 54 chunks |
| `.task` | Gemma 4 E2B web (1.91 GB) | GPU | **231 MB** | 191 ms | 234 chars/s (≈ 58.5 tok/s) | ✅ 95 chunks |
| `.task` | Gemma 4 E2B web (1.91 GB) | CPU | **470 MB** | 143 ms | 233 chars/s (≈ 58.3 tok/s) | ✅ |
| `.task` | Gemma 4 E2B web (1.91 GB) | GPU, prompt = "hi" | 369 MB | 211 ms | 264 chars/s (≈ 66 tok/s) | ✅ Clean monolingual English output |
| `.task` | Gemma 4 E4B web (2.83 GB) | GPU | **424 MB** | 5.2 s | 16 chars/s (≈ 4.1 tok/s) | ⚠️ Loads but output is numeric gibberish — upstream MediaPipe doesn't fully support 4B Gemma in v0.10.27 |
| `.task` | Gemma 4 E4B web (2.83 GB) | CPU | 382 MB | 272 ms | 10 chars/s (≈ 2.5 tok/s) | ⚠️ Same — output garbage |

**Four things this matrix proves:**

1. The dual-runtime architecture works — magic-byte sniff correctly routes `.litertlm` → `@litert-lm/core` and `.task` → `@mediapipe/tasks-genai`.
2. For models that fit web's memory budget, **MediaPipe `.task` is ~8× faster than LiteRT-LM `.litertlm`** on the same Gemma 3 1B (117 tok/s vs 14 tok/s). Web defaults should prefer `.task`.
3. **Streaming `ReadableStreamDefaultReader` is strictly better than `arrayBuffer()`** for the MediaPipe path: same output, same speed, ~10× lower JS heap (Gemma 4 E2B went from 1921 MB peak to 231 MB peak GPU / 470 MB peak CPU).
4. **Gemma 4 E2B is fully viable on web via `.task`** — the same model that the LiteRT-LM path can't load runs at ~58 tok/s on either backend with very modest heap.

**Notes:**

- The Gemma 4 E2B anti-scam prompt earlier in this matrix produced output that drifted into Chinese and Thai mid-paragraph. Subsequent testing with a simpler prompt (`"hi"`) produced clean monolingual English, so that drift is the model reaching for multilingual training data on a topic with heavy multilingual coverage, not a bug in our routing or in `@mediapipe/tasks-genai`. Applying a Gemma 4 chat-turn template would probably tighten output formatting but isn't required for usability.
- **Gemma 4 E4B output is gibberish** — model loads (424 MB peak), inference runs, but output is numeric tokens that aren't properly decoded. This is an upstream `@mediapipe/tasks-genai` v0.10.27 limitation that does not yet support 4B-param Gemma. File a tracking issue once a clean repro is isolated.

## What the page measures

- **peak MB** — `performance.memory.usedJSHeapSize` peak during the run.
  Chromium only; Firefox / Safari report 0 (no comparable API).
- **ttft** — wall time from `Engine.create()` completion to the first
  non-empty streaming chunk.
- **total** — wall time from `Engine.create()` completion to the end of the
  stream.
- **chars** — total characters in the generated response.
- **chars/s** — `chars ÷ total`. The `≈ N tok/s` shown alongside is a rough
  approximation (English text averages ~4 chars per token); do **not** quote
  it as a measured token rate.
- **chunks** — how many separate streaming chunks the `ReadableStream`
  delivered. Sometimes 1 (the whole response in a single chunk), sometimes
  many — `@litert-lm/core`'s buffering strategy is the deciding factor and
  is not under our control. We cannot measure decode rate separately from
  prefill / buffering with the current API surface; that's why this page
  does not display a `tok/s` figure as if it were measured precisely.

## Hosting (static, free)

This whole directory is a static app — no build step. The only requirement
is that the host sends the right COOP/COEP headers so `SharedArrayBuffer`
is available (the WASM runtimes need it). Two deploy paths are wired up:

### Option A — Cloudflare Pages (recommended)

Cloudflare Pages can set custom response headers via a static `_headers`
file (already included), so cross-origin isolation works **without any
client-side service-worker workaround**. Free tier covers it: unlimited
static requests, 500 builds/month, free custom domains, no Workers needed.

1. cloudflare.com → Workers & Pages → **Create application → Pages →
   Connect to Git** → pick `helenkwok/expo-litert-lm`.
2. Build settings:
   - **Production branch:** `main` (or whichever branch you want live)
   - **Build command:** *(leave blank — pure static)*
   - **Build output directory:** `example/web-demo`
3. Deploy. The included `_headers` file is picked up automatically and sets
   COOP/COEP for every path.

Once live, the URL will be something like
`https://expo-litert-lm.pages.dev/`.

### Option B — GitHub Pages

GitHub Pages can't set custom response headers, so cross-origin isolation
falls to `coi-serviceworker.js` (vendored here, MIT,
[gzuidhof/coi-serviceworker](https://github.com/gzuidhof/coi-serviceworker)).
It registers a service worker that injects COOP/COEP from inside the
browser, making the demo work without server-side support.

1. Repo Settings → Pages → Build and deployment → Source:
   **"GitHub Actions"**.
2. Merge a change that touches `example/web-demo/**` into `main` (or run
   the workflow manually from the Actions tab). The
   [`deploy-web-demo`](../../.github/workflows/deploy-web-demo.yml) workflow
   stages `index.html`, `coi-serviceworker.js`, `_headers` (harmless on
   Pages, used by Cloudflare) and this README into `_site/`, then publishes.
3. First visit installs the SW and reloads the page once. Subsequent loads
   are cross-origin-isolated immediately.

Either way, `serve.mjs` is for local dev only and is intentionally not
deployed — both Pages services serve static files themselves.

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
| "Array buffer allocation failed" / "RuntimeError: WebAssembly.Memory(): could not allocate memory" | Model is too large for the 32-bit WASM linear-memory budget. Try a smaller model — Gemma 3 1B INT4 (557 MB) works; Gemma 4 E2B (2.4 GB) does not currently fit. See the "Verified status" table above. |
| WebGPU backend errors out with `llm_litert_compiled_model_executor.cc:...` | `@litert-lm/core` v0.12.0's WebGPU path doesn't compile this model variant. Toggle to CPU. See the "Verified status" table above. |
| Output box shows red "Invalid magic number" after pick | The picked file is not a real `.litertlm`. Run `xxd <file> \| head -1` — real models start with `4c49 5445 5254 4c4d` (`LITERTLM`). HF "Access denied" pages from un-authed `curl` are a common cause; re-download with the `hf` CLI. |
| Output stops after 1 token | WebGPU adapter crashed. Toggle to CPU backend and re-run. Check the browser's DevTools → Console. |
