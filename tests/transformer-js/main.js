import { pipeline, env, AutoTokenizer, AutoModelForTokenClassification } from '@xenova/transformers';
// import { pipeline } from "@huggingface/transformers";

// Configure Transformers.js environment for the browser
env.allowLocalModels = true;   // strictly use local pre-downloaded models
env.useBrowserCache = true;    // cache in IndexedDB/CacheStorage
// ONNX/WASM runtime assets from CDN (not model files)
// Serve WASM locally via Vite middleware to avoid proxy/CDN issues
env.backends.onnx.wasm.wasmPaths = `/wasm/`;

// Wrap fetch to expose clearer errors (status/url)
const realFetch = env.fetch || fetch.bind(window);
env.fetch = async (url, options) => {
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
  'mrm8488/mobilebert-finetuned-ner',
  'gagan3012/bert-tiny-finetuned-ner',
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
    const modelPath = `/${base}`
    classifier = await pipeline('token-classification', modelPath, { quantized: !!quantized });
    outEl.textContent = `Model loaded successfully: ${modelPath}`;
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
    const ner = await ensurePipeline(modelId, quantized);
    const t0 = performance.now();
    const output = await ner(text, { aggregation_strategy: 'simple' });
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
