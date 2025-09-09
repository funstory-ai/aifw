import { pipeline, env, AutoTokenizer, AutoModelForTokenClassification } from '@xenova/transformers';
// import { pipeline } from "@huggingface/transformers";

// Configure Transformers.js environment for the browser
env.allowLocalModels = true;   // strictly use local pre-downloaded models
env.useBrowserCache = true;    // cache in IndexedDB/CacheStorage
// ONNX/WASM runtime assets from CDN (not model files)
// Serve WASM locally via Vite middleware to avoid proxy/CDN issues
env.backends.onnx.wasm.wasmPaths = `/wasm/`;

// Wrap fetch to expose clearer errors (status/url) and capture wasm asset used
const realFetch = env.fetch || fetch.bind(window);
env.fetch = async (url, options) => {
  try {
    if (typeof url === 'string' && url.includes('/wasm/') && url.endsWith('.wasm')) {
      try { window.__ortWasmAsset = url; } catch (_) {}
      console.log(`[EP] fetching wasm asset: ${url}`);
    }
  } catch (_) {}
  const res = await realFetch(url, options);
  if (!res.ok) {
    const ct = res.headers.get('content-type') || '';
    let snippet = '';
    try { snippet = (await res.text()).slice(0, 200); } catch (_) {}
    throw new Error(`Fetch failed: ${res.status} ${res.statusText} for ${url} (ct=${ct}) body=${JSON.stringify(snippet)}`);
  }
  return res;
};

// Supported models only
const SUPPORTED = new Set([
  'Xenova/distilbert-base-cased-finetuned-conll03-english',
  'gagan3012/bert-tiny-finetuned-ner',
  'dslim/distilbert-NER',
  'Mozilla/mobilebert-uncased-finetuned-LoRA-intent-classifier',
  'boltuix/NeuroBERT-Mini',
  'dmis-lab/TinyPubMedBERT-v1.0',
  'mrm8488/TinyBERT-spanish-uncased-finetuned-ner',
  'boltuix/NeuroBERT-Small',
]);

// Local directories for pre-downloaded assets (place under tests/transformer-js/public/models/...)
function localDirFor(modelId) {
  // Transformers.js (allowLocalModels=true) will resolve from /models/<id>
  // Return only the repo id here to avoid double "/models/" in URLs
  return `${modelId}`;
}

const runBtn = document.getElementById('run');
const textEl = document.getElementById('text');
const modelEl = document.getElementById('model');
const quantizedEl = document.getElementById('quantized');
const outEl = document.getElementById('out');

let classifier = null;

async function ensurePipeline(modelId, quantized) {
  if (classifier && classifier.model_id === modelId && classifier.quantized === !!quantized) return classifier;
  if (!SUPPORTED.has(modelId)) {
    throw new Error(`Unsupported model: ${modelId}`);
  }
  outEl.textContent = `Loading model ${modelId} from local assets ...`;
  const base = localDirFor(modelId);
  try {
    // Let pipeline load directly from local directory (env.allowLocalModels=true)
    const modelPath = `${base}`;
    // Configure EP chain: WebGPU -> WASM (threaded+SIMD by default)
    try {
      const cores = Math.max(1, Math.min(8, navigator.hardwareConcurrency || 4));
      env.backends.onnx.wasm.numThreads = cores;
      env.backends.onnx.wasm.simd = true;
    } catch (_) {}
    const providers = [];
    if (typeof navigator !== 'undefined' && 'gpu' in navigator) providers.push('webgpu');
    providers.push('wasm');
    classifier = await pipeline('token-classification', modelPath, { quantized: !!quantized, device: providers });
    // // Let pipeline load directly from local directory (env.allowLocalModels=true)
    // const modelPath = `${base}`
    // try {
    //   classifier = await pipeline('token-classification', modelPath, { quantized: !!quantized });
    // } catch (err) {
    //   const msg = String(err?.message || err)
    //   if (msg.toLowerCase().includes('unsupported model type')) {
    //     throw new Error(`This architecture is not supported by transformers.js ONNX runtime: ${msg}`)
    //   }
    //   if (quantized) {
    //     // Retry without quantization as fallback
    //     classifier = await pipeline('token-classification', modelPath, { quantized: false });
    //   } else {
    //     throw err
    //   }
    // }
    //  infer selected EP/provider and log it
    let provider = 'unknown';
    let detail = '';

    try {
      const hasWebGPU = typeof navigator !== 'undefined' && 'gpu' in navigator;
      const wasmAsset = (() => { try { return window.__ortWasmAsset; } catch (_) { return undefined; } })();

      if (!wasmAsset && hasWebGPU) {
        provider = 'webgpu';
      } else if (wasmAsset) {
        provider = 'wasm';
        if (wasmAsset.includes('threaded-simd') || wasmAsset.includes('simd-threaded')) {
          detail = 'threaded-simd';
        } else if (wasmAsset.includes('simd')) {
          detail = 'simd';
        } else {
          detail = 'baseline';
        }
      }
    } catch (_) {}

    const threads = (() => { try { return env.backends.onnx.wasm.numThreads; } catch (_) { return undefined; } })();
    const simd = (() => { try { return env.backends.onnx.wasm.simd; } catch (_) { return undefined; } })();

    console.log(`[EP] provider=${provider}${detail ? `(${detail})` : ''} threads=${threads} simd=${simd} wasm_asset=${window.__ortWasmAsset}`);
    outEl.textContent = `Model loaded successfully: ${modelPath} (provider=${provider}${detail ? `, ${detail}` : ''}${threads ? `, threads=${threads}` : ''}${simd !== undefined ? `, simd=${simd}` : ''})`;
  } catch (e) {
    const hintBase = `/models/${base}`
    const hint = `Ensure files exist under ${hintBase} (tokenizer.json, config.json, onnx/model${quantized ? '_quantized' : ''}.onnx).`;
    outEl.textContent = `Model load error: ${e?.message || e}. ${hint}`;
    throw e;
  }
  classifier.model_id = modelId;
  classifier.quantized = !!quantized;
  return classifier;
}

runBtn.addEventListener('click', async () => {
  try {
    const modelId = modelEl.value;
    const quantized = !!quantizedEl.checked;
    const text = textEl.value || '';
    let ner = await ensurePipeline(modelId, quantized);
    const t0 = performance.now();
    let output;
    try {
      output = await ner(text, { aggregation_strategy: 'simple' });
    } catch (err) {
      const msg = String(err?.message || err);
      if (quantized && /Invalid array length/i.test(msg)) {
        // Retry without quantization if runtime fails on quantized graph
        ner = await ensurePipeline(modelId, false);
        output = await ner(text, { aggregation_strategy: 'simple' });
      } else {
        throw err;
      }
    }
    const t1 = performance.now();
    const timeMs = Math.round(t1 - t0);
    console.log(`[NER] model=${modelId} quantized=${quantized} len=${text.length} time_ms=${timeMs}`);
    outEl.textContent = JSON.stringify({ time_ms: timeMs, model: modelId, quantized, output }, null, 2);
  } catch (e) {
    outEl.textContent = `Error: ${e?.message || e}`;
  }
});

// Auto-run once on load
runBtn.click();
