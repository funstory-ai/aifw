# OneAIFW WebApp (browser)

A minimal browser demo that loads the core WASM and calls:
- aifw_session_create
- aifw_session_mask
- aifw_session_restore
- aifw_session_destroy
- aifw_string_free

## Prerequisites
- Build the WASM static lib and produce aifw_core.wasm (wasm32-freestanding)
- Place `aifw_core.wasm` under the web root (served at `/aifw_core.wasm`)

## Run (with Vite)
You can reuse the Vite server from tests/transformer-js, or serve this folder directly with any static server:

```bash
# Option A: simple static server
cd apps/webapp
python3 -m http.server 8080
# open http://127.0.0.1:8080

# Option B: add a vite config if preferred (not included)
```

Open the page, type text, click Run. The demo masks sensitive info then restores it.
