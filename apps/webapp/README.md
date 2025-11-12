# OneAIFW WebApp

A browser demo based on aifw-js. It supports:
- Online development with Vite
- An offline demo page served with COOP/COEP (enables ORT threads/SIMD)
- Production build

## Prerequisites
- Monorepo managed by pnpm. This webapp depends on the local package `@oneaifw/aifw-js` via `workspace:*`.
- Node.js 18+ and pnpm 8+.

## Build aifw-js (in workspace)
From the repository root (skip if already built):
```bash
pnpm -w --filter @oneaifw/aifw-js build
```

## Online development (Vite)
From `apps/webapp`:
```bash
pnpm run dev
```
Open the URL printed in the terminal (typically `http://127.0.0.1:5173/`).

Notes:
- Calling `await init()` uses the managed mode by default, which fetches NER models and ORT wasm from the GitHub-hosted assets and caches them.
- To enable ORT threads/SIMD you need cross-origin isolation (COOP/COEP). Vite dev server doesn’t enable it by default; functionality works but might run with reduced performance. For full performance testing, use the “Offline demo” section below.

## Offline demo (with COOP/COEP)
The offline page is `aifw-offline.html`. Copy assets into `public/` and serve with the built-in COOP/COEP server:
```bash
cd apps/webapp
pnpm run offline      # copy @oneaifw/aifw-js dist to public/vendor/aifw-js, and copy aifw-offline.html into public/
pnpm run serve:coi    # start the local static server with COOP/COEP (default port 5500)
```
Then open:
```
http://127.0.0.1:5500/aifw-offline.html
```

Troubleshooting:
- If `http://127.0.0.1:5500/offline.html` returns 404, use `aifw-offline.html`, or run `pnpm run offline` to ensure the file has been copied into `public/`.

## Production build
From `apps/webapp`:
```bash
pnpm run build
```
Serve the generated `dist/` as static assets. It’s recommended to enable COOP/COEP response headers in production to fully leverage ORT threads/SIMD. You can adapt your own server or follow the idea from the offline demo server.

## Managed assets (at runtime)
- `@oneaifw/aifw-js` uses managed mode in `init()` by default: on first run it downloads models and ORT wasm from the hosted repository, verifies integrity (SHA3-256), and warms up browser Cache Storage for faster subsequent loads.
- Resource hosting repository on Hugginface

## Scripts
- `pnpm run dev`: start the Vite dev server.
- `pnpm run offline`: prepare offline demo assets into `public/`.
- `pnpm run serve:coi`: start a local static server with COOP/COEP (default port 5500).
- `pnpm run build`: production build into `dist/`.
