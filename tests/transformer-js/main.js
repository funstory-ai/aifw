import { env, AutoTokenizer, AutoModelForTokenClassification } from '@xenova/transformers';
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
    // Prepare tokenizer and model (manual flow)
    const tokenizer = await AutoTokenizer.from_pretrained(modelPath);
    const model = await AutoModelForTokenClassification.from_pretrained(modelPath, { quantized: !!quantized, device: providers });
    classifier = new TokenClassificationPipeline({ model, tokenizer });
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
  classifier.quantized = quantized;
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
      // run pipeline of token classification
      output = await ner.run(text);
    } catch (err) {
      const msg = String(err?.message || err);
      if (quantized && /Invalid array length/i.test(msg)) {
        // Retry without quantization if runtime fails on quantized graph
        ner = await ensurePipeline(modelId, false);
        output = await ner.run(text);
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

/**
 * Generate offsets (start, end) for each token based on tokenizer output
 * @param {string} text original input text
 * @param {object} enc tokenizer.encode(text) result
 * @returns {Array<{token: string, start: number|null, end: number|null}>}
 */
function computeOffsets(text, enc) {
  const tokens = enc.tokens;
  const offsets = [];

  let cursor = 0;
  for (let i = 0; i < tokens.length; i++) {
    const tok = tokens[i];

    // 特殊 token（[CLS], [SEP] 等）
    if (enc.special_tokens_mask && enc.special_tokens_mask[i] === 1) {
      offsets.push({ token: tok, start: null, end: null });
      continue;
    }

    // 处理 WordPiece 子词
    let normTok = tok.startsWith("##") ? tok.slice(2) : tok;

    // 在原始文本中查找 normTok
    const lowerText = text.toLowerCase();
    const lowerTok = normTok.toLowerCase();
    const start = lowerText.indexOf(lowerTok, cursor);

    if (start === -1) {
      offsets.push({ token: tok, start: null, end: null });
      continue;
    }

    const end = start + normTok.length;
    offsets.push({ token: tok, start, end });

    cursor = end;
  }

  return offsets;
}

// Compute offsets from tokens by scanning in original text
function computeOffsetsFromTokens(text, tokens) {
  const offsets = new Array(tokens.length);
  // Build lowercase original (preserves indices) and accent-stripped lowercase with index map
  const lowerText = text.toLowerCase();
  const strippedInfo = buildStrippedMap(lowerText);
  const strippedText = strippedInfo.stripped;
  const mapStrippedToOrig = strippedInfo.map; // map[i] -> original index in text for start of stripped char i

  let cursorLower = 0;    // cursor in lowerText
  let cursorStripped = 0; // cursor in strippedText

  for (let i = 0; i < tokens.length; i++) {
    const full = String(tokens[i] ?? '');
    const raw = full.startsWith('##') ? full.slice(2) : full;
    if (!raw) { offsets[i] = [cursorLower, cursorLower]; continue; }

    const tokLower = raw.toLowerCase();
    // 1) Try case-insensitive match on original (index preserved)
    let p = lowerText.indexOf(tokLower, cursorLower);
    if (p === -1) p = lowerText.indexOf(tokLower);
    if (p !== -1) {
      const s = p;
      const e = p + raw.length;
      offsets[i] = [s, e];
      cursorLower = e;
      // advance stripped cursor roughly to maintain monotonicity
      cursorStripped = findStrippedIndexAtOrAfter(mapStrippedToOrig, e);
      continue;
    }

    // 2) Try accent-insensitive match on stripped text and map back
    const tokStripped = stripAccents(tokLower);
    if (tokStripped) {
      let sp = strippedText.indexOf(tokStripped, cursorStripped);
      if (sp === -1) sp = strippedText.indexOf(tokStripped);
      if (sp !== -1) {
        const startOrig = mapStrippedToOrig[sp] ?? 0;
        const after = sp + tokStripped.length;
        const endOrig = after < mapStrippedToOrig.length ? mapStrippedToOrig[after] : text.length;
        offsets[i] = [startOrig, endOrig];
        cursorLower = endOrig;
        cursorStripped = after;
        continue;
      }
    }

    // 3) Fallback: zero-length at current cursor
    offsets[i] = [cursorLower, cursorLower];
  }
  return offsets;
}

function mergeSubwordItems(items) {
  if (!Array.isArray(items) || items.length === 0) return items;
  const out = [];
  let cur = null;
  let count = 0;
  const core = (e) => (e.startsWith('B-') || e.startsWith('I-')) ? e.slice(2) : e;

  for (const it of items) {
    if (!cur) {
      cur = { ...it };
      count = 1;
      continue;
    }
    const sameEntity = core(cur.entity) === core(it.entity);
    const contiguous = cur.end === it.start;
    if (sameEntity && contiguous) {
      // merge
      cur.word = cur.word + it.word;
      cur.end = it.end;
      // average score incrementally
      cur.score = (cur.score * count + it.score) / (count + 1);
      count += 1;
      // keep index of first
    } else {
      out.push(cur);
      cur = { ...it };
      count = 1;
    }
  }
  if (cur) out.push(cur);
  return out;
}

function stripAccents(s) {
  try {
    return s.normalize('NFD').replace(/\p{M}+/gu, '');
  } catch (_) {
    // Fallback if Unicode property escapes unsupported
    return s;
  }
}

function buildStrippedMap(s) {
  // Build stripped string by removing combining marks and connector/hyphen-like punctuation,
  // and a map from stripped index to original index
  const outChars = [];
  const map = [];
  let i = 0;
  while (i < s.length) {
    const cp = s.codePointAt(i);
    const char = String.fromCodePoint(cp);
    const norm = char.normalize('NFD');
    for (let j = 0; j < norm.length; j++) {
      const ch = norm[j];
      // Drop combining marks and connector punctuation (hyphens/dashes/apostrophes/middle dots)
      if (/\p{M}/u.test(ch)) continue;
      if (isConnectorPunct(ch)) continue;
      outChars.push(ch);
      map.push(i); // map stripped position to original start index of this base char
    }
    i += char.length; // advance by code point length
  }
  return { stripped: outChars.join(''), map };
}

function isConnectorPunct(ch) {
  // Hyphen-minus, various Unicode dashes, minus sign, apostrophes, middle dot, bullet-like
  return /[-'`\u2010-\u2015\u2212\u00B7\u30FB\u2043\u2219]/u.test(ch);
}

function findStrippedIndexAtOrAfter(map, origIndex) {
  // binary search first map[pos] >= origIndex
  let lo = 0, hi = map.length;
  while (lo < hi) {
    const mid = (lo + hi) >>> 1;
    if (map[mid] < origIndex) lo = mid + 1; else hi = mid;
  }
  return lo;
}

// Decode logits to token classification items (no aggregation)
// function decodeTokenClassification(logits, tokens, id2label) {
//   // logits: Tensor with dims [batch, seq, num_labels], batch assumed 1
//   const dims = logits.dims || [];
//   const batch = dims[0] || 1;
//   const seqLen = dims[1] || (tokens ? tokens.length : 0);
//   const numLabels = dims[2] || 0;
//   const data = logits.data; // Float32Array length = batch*seq*num_labels
//   const items = [];
//   if (batch !== 1 || !numLabels || !data) return items;
// 
//   // Build plain tokens list (skip specials via empty decode upstream if needed)
//   const plainTokens = Array.isArray(tokens) ? tokens.filter(w => w && w !== '[PAD]' && w !== '[CLS]' && w !== '[SEP]') : [];
// 
//   for (let j = 0; j < seqLen; j++) {
//     const base = j * numLabels;
//     if (base + numLabels > data.length) break;
//     let maxIdx = 0, maxVal = -Infinity;
//     for (let k = 0; k < numLabels; k++) {
//       const v = data[base + k];
//       if (v > maxVal) { maxVal = v; maxIdx = k; }
//     }
//     const entity = id2label ? id2label[maxIdx] : `LABEL_${maxIdx}`;
//     if (entity === 'O') continue;
//     const word = tokens && tokens[j] ? String(tokens[j]) : '';
//     if (!word || word === '[PAD]' || word === '[CLS]' || word === '[SEP]') continue;
//     items.push({ entity, score: 1, index: j + 1, word, start: null, end: null });
//   }
//   return items;
// }

class TokenClassificationPipeline {
    /**
     * Create a new TokenClassificationPipeline.
     * @param {Object} options An object containing the following properties:
     * @param {PreTrainedModel} [options.model] The model used by the pipeline.
     * @param {PreTrainedTokenizer} [options.tokenizer=null] The tokenizer used by the pipeline (if any).
     * @param {Processor} [options.processor=null] The processor used by the pipeline (if any).
     */
    constructor({ model, tokenizer = null, processor = null }) {
        this.model = model;
        this.tokenizer = tokenizer;
        this.processor = processor;
    }

    async run(text, { ignore_labels = ['O'] } = {}) {
      // 1) Tokenize with specials (align with model)
      const enc = this.tokenizer([text], { padding: true, truncation: true, add_special_tokens: true });
      const idsRow = enc.input_ids[0];          // Tensor row
      const seqLen = idsRow.dims[0];            // sequence length

      // 2) build tokensPlain and mapping
      const tokensPlain = [];
      const seqIndexToPlainIndex = new Array(seqLen).fill(-1);
      for (let j = 0; j < seqLen; j++) {
        const id = idsRow[j].item();
        const word = this.tokenizer.decode([id], { skip_special_tokens: true });
        if (word) {
          const plainIdx = tokensPlain.length;
          seqIndexToPlainIndex[j] = plainIdx;
          tokensPlain.push(word.startsWith('##') ? word.slice(2) : word);
        }
      }

      // 3) compute offsets
      const offsets = computeOffsetsFromTokens(text, tokensPlain); // [[start,end), ...]

      // 4) model inference
      const outputs = await this.model(enc);
      const logits = outputs.logits;              // [1, seq, num_labels]
      const dims = logits.dims || [];
      const numLabels = dims[2] || 0;
      const data = logits.data;
      const id2label = this.model.config.id2label;

      // 5) decode token classification results and fill start/end (map by seqIndexToPlainIndex)
      const items = [];
      for (let j = 0; j < seqLen; j++) {
        if (!numLabels || !data) break;
        const base = j * numLabels;
        if (base + numLabels > data.length) break;
        // get the max label at this position
        let maxIdx = 0, maxVal = -Infinity;
        for (let k = 0; k < numLabels; k++) {
          const v = data[base + k];
          if (v > maxVal) { maxVal = v; maxIdx = k; }
        }
        // stable softmax score for the top label
        let sumExp = 0;
        for (let k = 0; k < numLabels; k++) {
          sumExp += Math.exp(data[base + k] - maxVal);
        }
        const score = sumExp > 0 ? Math.exp(data[base + maxIdx] - maxVal) / sumExp : 0;
        const entity = id2label ? id2label[maxIdx] : `LABEL_${maxIdx}`;
        if (ignore_labels.includes(entity)) continue;

        // skip special (plainIndex < 0 means special)
        const plainIndex = seqIndexToPlainIndex[j];
        if (plainIndex < 0) continue;

        const word = tokensPlain[plainIndex] || '';
        const off = offsets[plainIndex] || [null, null];
        items.push({
          entity,
          score,
          index: j,
          word,
          start: off[0],
          end: off[1],
        });
      }

      const merged = mergeSubwordItems(items);
      return merged;
    }

    // async run(text, {
    //     ignore_labels = ['O'],
    // } = {}) {
    //     // Run tokenization
    //     const model_inputs = this.tokenizer([text], {
    //         padding: true,
    //         truncation: true,
    //         add_special_tokens: false,
    //     });

    //     const offsets = computeOffsets(text, model_inputs);
    //     console.log('pipeline token offsets', offsets);

    //     // Run model
    //     const outputs = await this.model(model_inputs)
    //     const logits = outputs.logits;
    //     const id2label = this.model.config.id2label;

    //     const toReturn = [];
    //     for (let i = 0; i < logits.dims[0]; ++i) {
    //         const ids = model_inputs.input_ids[i];
    //         const batch = logits[i];

    //         // List of tokens that aren't ignored
    //         const tokens = [];
    //         for (let j = 0; j < batch.dims[0]; ++j) {
    //             const tokenData = batch[j];
    //             const topScoreIndex = (0,_utils_maths_js__WEBPACK_IMPORTED_MODULE_4__.max)(tokenData.data)[1];

    //             const entity = id2label ? id2label[topScoreIndex] : `LABEL_${topScoreIndex}`;
    //             if (ignore_labels.includes(entity)) {
    //                 // We predicted a token that should be ignored. So, we skip it.
    //                 continue;
    //             }

    //             // TODO add option to keep special tokens?
    //             const word = this.tokenizer.decode([ids[j].item()], { skip_special_tokens: true });
    //             if (word === '') {
    //                 // Was a special token. So, we skip it.
    //                 continue;
    //             }

    //             const scores = (0,_utils_maths_js__WEBPACK_IMPORTED_MODULE_4__.softmax)(tokenData.data);

    //             tokens.push({
    //                 entity: entity,
    //                 score: scores[topScoreIndex],
    //                 index: j,
    //                 word: word,

    //                 // TODO: null for now, but will add
    //                 start: offsets[j-1][0],
    //                 end: offsets[j-1][1],
    //             });
    //         }
    //         toReturn.push(tokens);
    //     }
    //     return isBatched ? toReturn : toReturn[0];
    // }
}

