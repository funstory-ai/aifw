// aifw-extension-sample.js
// Initialize aifw-js using vendor bundle and serve model files from IndexedDB via a fetch shim.

import * as aifw from './vendor/aifw-js/aifw-js.js'
import { getFromCache, putToCache } from './indexeddb-models.js'

// Logical base used by aifw-js to request models
export const modelsBase = 'https://aifw-js.local/models/'

// Example remote base hosting the model assets (downloaded once, then cached)
export const remoteBase = 'https://s.immersivetranslate.com/assets/OneAIFW/Models/20250926/'

export const defaultModelId = 'funstory-ai/neurobert-mini'

try {
  console.log('crossOriginIsolated=', globalThis.crossOriginIsolated);
  if (!globalThis.crossOriginIsolated &&
      navigator.hardwareConcurrency &&
      navigator.hardwareConcurrency > 1) {
    // Force setting navigator.hardwareConcurrency to 1 for avoid importScript errors
    Object.defineProperty(navigator, 'hardwareConcurrency', { value: 1, configurable: true });
  }
} catch {}

export async function ensureModelCached(modelId = defaultModelId, base = remoteBase) {
  const files = [
    'tokenizer.json',
    'tokenizer_config.json',
    'config.json',
    'special_tokens_map.json',
    'vocab.txt',
    'onnx/model_quantized.onnx',
  ]
  for (const rel of files) {
    const url = base.replace(/\/?$/, '/') + rel
    const res = await fetch(url)
    if (!res.ok) throw new Error('download failed: ' + url)
    const ct = res.headers.get('Content-Type') || (rel.endsWith('.json') ? 'application/json; charset=utf-8' : 'application/octet-stream')
    // Store under modelsBase + modelId + '/' + rel
    const cacheUrl = `${modelsBase}${modelId}/${rel}`
    await putToCache(cacheUrl, res, ct)
  }
}

function installModelsFetchShim() {
  const base = modelsBase.endsWith('/') ? modelsBase : modelsBase + '/'
  const origFetch = globalThis.fetch.bind(globalThis)
  globalThis.fetch = async (input, init) => {
    try {
      const url = typeof input === 'string' ? input : input.url
      if (String(url).startsWith(base)) {
        const data = await getFromCache(String(url))
        if (data) {
          const u8 = data instanceof Uint8Array ? data : new Uint8Array(data)
          const ct = String(url).endsWith('.json') ? 'application/json; charset=utf-8'
            : String(url).endsWith('.onnx') ? 'application/octet-stream'
            : String(url).endsWith('.txt') ? 'text/plain; charset=utf-8'
            : 'application/octet-stream'
          return new Response(new Blob([u8], { type: ct }), { status: 200 })
        }
      }
    } catch (e) {
      // fallthrough to network
    }
    return origFetch(input, init)
  }
}

export async function initAifwWithCache({ wasmBase } = {}) {
  installModelsFetchShim()
  await aifw.init({
    wasmBase: wasmBase || chrome.runtime.getURL('vendor/aifw-js/wasm/'),
    modelsBase
  })
  return aifw
}
