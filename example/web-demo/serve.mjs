#!/usr/bin/env node
// Tiny static server with COOP/COEP headers for SharedArrayBuffer.
//
// The @litert-lm/core WASM runtime uses SharedArrayBuffer for threading. SAB
// is only exposed when the page is *cross-origin isolated* — which requires:
//   Cross-Origin-Opener-Policy:   same-origin
//   Cross-Origin-Embedder-Policy: require-corp
//
// No npm install needed — uses only node:http / node:fs / node:path from the
// Node 18+ standard library.
//
// Usage:
//   cd example/web-demo
//   # Drop gemma3-1b-it-int4.litertlm in this directory first, then:
//   node serve.mjs
//   # Open http://localhost:8000/

import { createServer } from 'node:http';
import { readFile, stat } from 'node:fs/promises';
import { extname, join, resolve, sep } from 'node:path';

const PORT = Number(process.env.PORT ?? 8000);
const ROOT = resolve(process.cwd());

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.css':  'text/css; charset=utf-8',
  '.js':   'text/javascript; charset=utf-8',
  '.mjs':  'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.wasm': 'application/wasm',
  '.svg':  'image/svg+xml',
  '.png':  'image/png',
  '.litertlm': 'application/octet-stream',
};

const server = createServer(async (req, res) => {
  // Cross-origin isolation (must be on EVERY response, including 404s).
  res.setHeader('Cross-Origin-Opener-Policy', 'same-origin');
  res.setHeader('Cross-Origin-Embedder-Policy', 'require-corp');
  // Allow our own resources to embed under require-corp.
  res.setHeader('Cross-Origin-Resource-Policy', 'same-origin');

  try {
    let urlPath = decodeURIComponent((req.url ?? '/').split('?')[0]);
    if (urlPath.endsWith('/')) urlPath += 'index.html';

    // Block traversal outside ROOT.
    const filePath = resolve(join(ROOT, urlPath));
    if (!filePath.startsWith(ROOT + sep) && filePath !== ROOT) {
      res.writeHead(403).end('forbidden');
      return;
    }

    const s = await stat(filePath);
    if (!s.isFile()) {
      res.writeHead(404).end('not found');
      return;
    }

    const type = MIME[extname(filePath).toLowerCase()] ?? 'application/octet-stream';
    res.setHeader('Content-Type', type);
    res.setHeader('Content-Length', String(s.size));
    res.writeHead(200);
    res.end(await readFile(filePath));
  } catch (e) {
    if (e?.code === 'ENOENT') {
      res.writeHead(404).end('not found');
    } else {
      res.writeHead(500).end(String(e?.message ?? e));
    }
  }
});

server.listen(PORT, 'localhost', () => {
  console.log(`Serving on http://localhost:${PORT}/  (COOP/COEP enabled)`);
  console.log('Stop with Ctrl-C.');
});
