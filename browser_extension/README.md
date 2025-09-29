# OneAIFW Browser Extension

This extension anonymizes and restores selected text using the `@oneaifw/aifw-js` library. Models are downloaded once and cached in IndexedDB; ONNX/WASM runtimes are bundled.

## Build / Pack

1) Build the aifw-js library and stage assets into the extension:

```sh
pnpm -w --filter @oneaifw/aifw-js build
# copy vendor bundle + wasm into the extension
mkdir -p browser_extension/vendor/aifw-js
rsync -a --exclude 'models' libs/aifw-js/dist/* browser_extension/vendor/aifw-js
```

2) Load extension in Chrome/Edge:
- Open chrome://extensions
- Enable Developer mode
- Load unpacked → select `browser_extension` directory

3) First-run:
- On install, the extension downloads the model files from the remote base (see `aifw-extension-sample.js`) and stores in IndexedDB
- Right-click selection → “Anonymize with OneAIFW” or “Restore with OneAIFW”

## Config
- Remote model base: `browser_extension/aifw-extension-sample.js` (`remoteBase`)
- Model id: `defaultModelId`
- WASM base is served from `vendor/aifw-js/wasm/` inside the extension

## How it works
- `env.fetch` is overridden so requests to `modelsBase` come from IndexedDB instead of the network
- The first installation populates IndexedDB via `ensureModelCached`

## Browser store policies (WASM)
- Chrome Web Store and Firefox AMO generally require that executable code (including WASM binaries) be packaged with the extension and not downloaded at runtime for review and security reasons.
- This project packages all ORT/AIFW WASM files under `vendor/aifw-js/wasm/` and declares them in `web_accessible_resources`.
- Model files are large and dynamic; they are cached in IndexedDB by user action. If your store review requires models to be packaged, you can copy the desired model directory into `vendor/aifw-js/models/` and omit the remote download step.

## Development Notes
- If you change `@oneaifw/aifw-js`, rebuild and re-copy `libs/aifw-js/dist` into `browser_extension/vendor/aifw-js`
- If you want to pin a different model, update `remoteBase` and `defaultModelId`
