import { env, AutoTokenizer, AutoModelForTokenClassification } from '@xenova/transformers';

export function initEnv({ wasmBase = '/wasm/', threads, simd } = {}) {
  env.allowLocalModels = true;
  env.useBrowserCache = true;
  env.backends.onnx.wasm.wasmPaths = wasmBase;
  if (typeof threads === 'number' && threads > 0) env.backends.onnx.wasm.numThreads = threads;
  if (typeof simd === 'boolean') env.backends.onnx.wasm.simd = simd;
}

export const SUPPORTED = new Set([
  'Xenova/distilbert-base-cased-finetuned-conll03-english',
  'gagan3012/bert-tiny-finetuned-ner',
  'dslim/distilbert-NER',
  'funstory-ai/neurobert-mini',
  'boltuix/NeuroBERT-Mini',
  'dmis-lab/TinyPubMedBERT-v1.0',
  'mrm8488/TinyBERT-spanish-uncased-finetuned-ner',
  'boltuix/NeuroBERT-Small',
]);

function localDirFor(modelId) {
  return `${modelId}`;
}

export class TokenClassificationPipeline {
  constructor({ model, tokenizer = null, processor = null }) {
    this.model = model;
    this.tokenizer = tokenizer;
    this.processor = processor;
  }

  async run(text, { ignore_labels = ['O'] } = {}) {
    const enc = this.tokenizer([text], { padding: true, truncation: true, add_special_tokens: true });
    const idsRow = enc.input_ids[0];
    const seqLen = idsRow.dims[0];

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

    const offsets = computeOffsetsFromTokens(text, tokensPlain);

    const outputs = await this.model(enc);
    const logits = outputs.logits;
    const dims = logits.dims || [];
    const numLabels = dims[2] || 0;
    const data = logits.data;
    const id2label = this.model.config.id2label;

    const items = [];
    for (let j = 0; j < seqLen; j++) {
      if (!numLabels || !data) break;
      const base = j * numLabels;
      if (base + numLabels > data.length) break;
      let maxIdx = 0, maxVal = -Infinity;
      for (let k = 0; k < numLabels; k++) {
        const v = data[base + k];
        if (v > maxVal) { maxVal = v; maxIdx = k; }
      }
      let sumExp = 0;
      for (let k = 0; k < numLabels; k++) sumExp += Math.exp(data[base + k] - maxVal);
      const score = sumExp > 0 ? Math.exp(data[base + maxIdx] - maxVal) / sumExp : 0;
      const entity = id2label ? id2label[maxIdx] : `LABEL_${maxIdx}`;
      if (ignore_labels.includes(entity)) continue;

      const plainIndex = seqIndexToPlainIndex[j];
      if (plainIndex < 0) continue;

      const word = tokensPlain[plainIndex] || '';
      const off = offsets[plainIndex] || [null, null];
      items.push({ entity, score, index: j, word, start: off[0], end: off[1] });
    }

    return mergeSubwordItems(items);
  }
}

export async function buildNerPipeline(modelId, { quantized = true, preferWebGPU = true } = {}) {
  if (!SUPPORTED.has(modelId)) throw new Error(`Unsupported model: ${modelId}`);
  const base = localDirFor(modelId);
  const modelPath = `${base}`;
  const tokenizer = await AutoTokenizer.from_pretrained(modelPath);
  const device = [];
  if (preferWebGPU && typeof navigator !== 'undefined' && 'gpu' in navigator) device.push('webgpu');
  device.push('wasm');
  const model = await AutoModelForTokenClassification.from_pretrained(modelPath, { quantized: !!quantized, device });
  return new TokenClassificationPipeline({ model, tokenizer });
}

export function computeOffsetsFromTokens(text, tokens) {
  const offsets = new Array(tokens.length);
  const lowerText = text.toLowerCase();
  const strippedInfo = buildStrippedMap(lowerText);
  const strippedText = strippedInfo.stripped;
  const mapStrippedToOrig = strippedInfo.map;

  let cursorLower = 0;
  let cursorStripped = 0;

  for (let i = 0; i < tokens.length; i++) {
    const full = String(tokens[i] ?? '');
    const raw = full.startsWith('##') ? full.slice(2) : full;
    if (!raw) { offsets[i] = [cursorLower, cursorLower]; continue; }

    const tokLower = raw.toLowerCase();
    let p = lowerText.indexOf(tokLower, cursorLower);
    if (p === -1) p = lowerText.indexOf(tokLower);
    if (p !== -1) {
      const s = p;
      const e = p + raw.length;
      offsets[i] = [s, e];
      cursorLower = e;
      cursorStripped = findStrippedIndexAtOrAfter(mapStrippedToOrig, e);
      continue;
    }

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

    offsets[i] = [cursorLower, cursorLower];
  }
  return offsets;
}

export function mergeSubwordItems(items) {
  if (!Array.isArray(items) || items.length === 0) return items;
  const out = [];
  let cur = null;
  let count = 0;
  const core = (e) => (e.startsWith('B-') || e.startsWith('I-')) ? e.slice(2) : e;

  for (const it of items) {
    if (!cur) { cur = { ...it }; count = 1; continue; }
    const sameEntity = core(cur.entity) === core(it.entity);
    const contiguous = cur.end === it.start;
    if (sameEntity && contiguous) {
      cur.word = cur.word + it.word;
      cur.end = it.end;
      cur.score = (cur.score * count + it.score) / (count + 1);
      count += 1;
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
  try { return s.normalize('NFD').replace(/\p{M}+/gu, ''); } catch { return s; }
}

function buildStrippedMap(s) {
  const outChars = [];
  const map = [];
  let i = 0;
  while (i < s.length) {
    const cp = s.codePointAt(i);
    const char = String.fromCodePoint(cp);
    const norm = char.normalize('NFD');
    for (let j = 0; j < norm.length; j++) {
      const ch = norm[j];
      if (/\p{M}/u.test(ch)) continue;
      if (isConnectorPunct(ch)) continue;
      outChars.push(ch);
      map.push(i);
    }
    i += char.length;
  }
  return { stripped: outChars.join(''), map };
}

function isConnectorPunct(ch) {
  return /[-'`\u2010-\u2015\u2212\u00B7\u30FB\u2043\u2219]/u.test(ch);
}

function findStrippedIndexAtOrAfter(map, origIndex) {
  let lo = 0, hi = map.length;
  while (lo < hi) {
    const mid = (lo + hi) >>> 1;
    if (map[mid] < origIndex) lo = mid + 1; else hi = mid;
  }
  return lo;
}

// Build a WASM buffer of NerRecogEntity (wasm32 layout):
// struct { char* entity; float score; uint32 index; uint32 start; uint32 end; }
export function buildNerEntitiesBuffer(wasm, items, textLen) {
  if (!items?.length) return { ptr: 0, count: 0, owned: [], byteSize: 0 };
  const structSize = 20;
  const count = items.length >>> 0;
  const total = structSize * count;
  const arrPtr = wasm.aifw_malloc(total);
  if (!arrPtr) throw new Error('aifw_malloc ner entities failed');
  const dv = new DataView(wasm.memory.buffer);
  const owned = [];
  const getPtrFor = (s) => {
    const bytes = new TextEncoder().encode(String(s));
    const buf = new Uint8Array(bytes.length + 1);
    buf.set(bytes); buf[bytes.length] = 0;
    const p = wasm.aifw_malloc(buf.length);
    new Uint8Array(wasm.memory.buffer, p, buf.length).set(buf);
    owned.push({ ptr: p, size: buf.length });
    return p;
  };
  for (let i = 0; i < count; i++) {
    const it = items[i];
    let s = Math.max(0, Math.min(textLen, Number(it.start || 0)));
    let e = Math.max(s, Math.min(textLen, Number(it.end || 0)));
    const base = arrPtr + i * structSize;
    dv.setUint32(base + 0, getPtrFor(String(it.entity || 'B-MISC')), true);
    dv.setFloat32(base + 4, Number(it.score || 0), true);
    dv.setUint32(base + 8, Number(it.index || 0) >>> 0, true);
    dv.setUint32(base + 12, s >>> 0, true);
    dv.setUint32(base + 16, e >>> 0, true);
  }
  return { ptr: arrPtr, count, owned, byteSize: total };
}
