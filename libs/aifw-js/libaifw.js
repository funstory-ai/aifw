let session = null;
let wasm = null;
let nerLib = null;
let nerPipelines = {
  default: null,
  zh: null,
};

// Helpers
export class MatchedPIISpan {
  constructor(entity_id, entity_type, matched_start, matched_end) {
    this.entity_id = entity_id >>> 0;
    this.entity_type = entity_type >>> 0;
    this.matched_start = matched_start >>> 0;
    this.matched_end = matched_end >>> 0;
  }
}

function allocZigStrFromJs(str) {
  const enc = new TextEncoder();
  const bytes = enc.encode(str || '');
  const size = bytes.length + 1;
  const ptr = wasm.aifw_malloc(size);
  if (!ptr) throw new Error('aifw_malloc failed');
  const mem = new Uint8Array(wasm.memory.buffer, ptr, size);
  mem.set(bytes, 0);
  mem[bytes.length] = 0; // NUL terminator
  return { ptr, size };
}

function readZigStr(ptr) {
  const mem = new Uint8Array(wasm.memory.buffer);
  let end = ptr;
  while (mem[end] !== 0) end++;
  return new TextDecoder().decode(mem.subarray(ptr, end));
}

function freeBuf(ptr, size) {
  if (!ptr || !size) return;
  wasm.aifw_free_sized(ptr, size);
}

async function loadAifwCore(wasmBase) {
  const imports = {
    env: {
      js_log(level, ptr, len) {
        try {
          const mem = new Uint8Array(wasm.memory?.buffer || new ArrayBuffer(0));
          const view = new Uint8Array(mem.buffer, ptr, len);
          const msg = new TextDecoder().decode(view);
          const tag = ["ERR", "WRN", "INF", "DBG"][level] || "LOG";
          console.log(`[aifw_core:${tag}]`, msg);
        } catch (_) {}
      },
    },
  };
  let urlStr;
  if (wasmBase) {
    const base = wasmBase.endsWith('/') ? wasmBase : wasmBase + '/';
    urlStr = base + 'liboneaifw_core.wasm';
  } else {
    urlStr = new URL(/* @vite-ignore */ './wasm/liboneaifw_core.wasm', import.meta.url).toString();
  }
  // cache-bust to avoid stale core wasm in extension/webapp
  const bust = (urlStr.includes('?') ? '&' : '?') + 'v=' + Date.now();
  const resp = await fetch(urlStr + bust, { cache: 'no-store' });
  if (!resp.ok) throw new Error(`fetch core wasm failed: ${resp.status}`);
  const bytes = await resp.arrayBuffer();
  const { instance } = await WebAssembly.instantiate(bytes, imports);
  const wasm_exports = instance.exports;
  if (!wasm_exports.aifw_malloc || !wasm_exports.aifw_free_sized) {
    console.warn('alloc exports missing; available exports:', Object.keys(wasm_exports));
  }
  return wasm_exports;
}

export async function init({ wasmBase = '/wasm/', modelsBase = '/models/' }) {
  // load aifw core wasm library
  wasm = await loadAifwCore(wasmBase);
  // load NER lib and pipeline (relative import for packaged lib)
  nerLib = await import('./libner.js');

  // Force SIMD on, and set threads from hardwareConcurrency (>=1)
  const threads = (typeof navigator !== 'undefined' && navigator.hardwareConcurrency) ? Math.max(1, navigator.hardwareConcurrency) : 1;
  nerLib.initEnv({ wasmBase, modelsBase, threads, simd: true });

  // Preload NER pipelines for EN(default) and ZH
  const enModelId = 'funstory-ai/neurobert-mini';
  const zhModelId = 'ckiplab/bert-tiny-chinese-ner';
  const [enPipe, zhPipe] = await Promise.all([
    nerLib.buildNerPipeline(enModelId, { quantized: true }).catch((e) => { console.warn('load EN model failed', e); return null; }),
    nerLib.buildNerPipeline(zhModelId, { quantized: true }).catch((e) => { console.warn('load ZH model failed', e); return null; }),
  ]);
  nerPipelines.default = enPipe;
  nerPipelines.zh = zhPipe || enPipe;
  if (!zhPipe) {
    console.warn('load zh NER model failed, using en model instead.');
  }

  session = await createSession();
}

export async function deinit() {
  if (session) await destroySession(session);
  wasm.aifw_shutdown();
  // nothing special; GC will collect JS objects
  session = null;
  nerPipelines = { default: null, zh: null };
  nerLib = null;
  wasm = null;
}

async function createSession() {
  if (!wasm) throw new Error('AIFW not initialized');
  // default ner_recog_type = token_classification (0)
  const initBuf = new Uint8Array(4);
  const initAlloc = wasm.aifw_malloc(initBuf.length);
  new Uint8Array(wasm.memory.buffer, initAlloc, initBuf.length).set(initBuf);
  new DataView(wasm.memory.buffer).setUint32(initAlloc + 0, 0, true);

  let session = {};
  try {
    session.handle = wasm.aifw_session_create(initAlloc);
    if (!session.handle) throw new Error('session_create failed');
  } finally {
    // init buffer can be freed immediately after creation
    freeBuf(initAlloc, initBuf.length);
  }
  return session;
}

async function destroySession(session) {
  if (!wasm || !session?.handle) throw new Error('invalid session handle');
  try {
    wasm.aifw_session_destroy(session.handle);
  } finally {
    session.handle = 0;
  }
}

function selectNer(language) {
  const lang = String(language || '').toLowerCase();
  // Treat zh, zh-cn, zh-tw, zh-hans, zh-hant as Chinese
  if (lang === 'zh' || lang.startsWith('zh-')) {
    console.log('select zh NER pipeline.');
    return nerPipelines.zh || nerPipelines.default;
  }
  console.log('select en NER pipeline.', nerPipelines.default);
  return nerPipelines.default;
}

export async function maskText(inputText, language) {
  if (!wasm || !session?.handle) throw new Error('invalid session handle');
  const nerPipe = selectNer(language);
  if (!nerPipe) throw new Error('NER pipeline not ready');

  let zigInputText = null;
  let nerBuf = null;
  let outMaskedPtrPtr = 0;
  let outMaskMetaPtrPtr = 0;
  try {
    zigInputText = allocZigStrFromJs(inputText);
    const items = await nerPipe.run(inputText);
    nerBuf = nerLib.buildNerEntitiesBuffer(wasm, items, inputText);

    outMaskedPtrPtr = wasm.aifw_malloc(4);
    outMaskMetaPtrPtr = wasm.aifw_malloc(4);
    const rcMask = wasm.aifw_session_mask_and_out_meta(session.handle, zigInputText.ptr, nerBuf.ptr, nerBuf.count >>> 0, outMaskedPtrPtr, outMaskMetaPtrPtr);
    if (rcMask !== 0) throw new Error(`mask failed rc=${rcMask}`);
    const maskedPtr = new DataView(wasm.memory.buffer).getUint32(outMaskedPtrPtr, true);
    const maskedStr = readZigStr(maskedPtr);
    // free masked core string after copying out
    wasm.aifw_string_free(maskedPtr);
    const maskMetaPtr = new DataView(wasm.memory.buffer).getUint32(outMaskMetaPtrPtr, true);
    const metaLen = new DataView(wasm.memory.buffer).getUint32(maskMetaPtr, true);
    const maskMeta = new Uint8Array(metaLen);
    const zigMaskMeta = new Uint8Array(wasm.memory.buffer, maskMetaPtr, metaLen);
    maskMeta.set(zigMaskMeta);
    // free core-owned serialized meta buffer after copying out
    freeBuf(maskMetaPtr, metaLen);
    return [maskedStr, maskMeta];
  } finally {
    if (outMaskedPtrPtr) freeBuf(outMaskedPtrPtr, 4);
    if (outMaskMetaPtrPtr) freeBuf(outMaskMetaPtrPtr, 4);
    if (nerBuf?.ptr) freeBuf(nerBuf.ptr, nerBuf.byteSize);
    if (nerBuf?.owned) for (const s of nerBuf.owned) freeBuf(s.ptr, s.size);
    if (zigInputText) freeBuf(zigInputText.ptr, zigInputText.size);
  }
}

export async function restoreText(maskedText, maskMeta) {
  if (!wasm || !session?.handle) throw new Error('invalid session');

  let zigMaskedText = null;
  let outRestoredPtrPtr = 0;
  let zigMaskMetaPtr = 0;
  let zigMaskMetaSize = 0;
  try {
    zigMaskedText = allocZigStrFromJs(maskedText);
    // Prepare serialized meta in WASM memory
    const metaBytes = (maskMeta instanceof Uint8Array) ? maskMeta : new Uint8Array(maskMeta);
    if (metaBytes.length < 4) throw new Error('invalid maskMeta');
    zigMaskMetaSize = metaBytes.length;
    zigMaskMetaPtr = wasm.aifw_malloc(zigMaskMetaSize);
    if (!zigMaskMetaPtr) throw new Error('aifw_malloc failed (meta)');
    new Uint8Array(wasm.memory.buffer, zigMaskMetaPtr, zigMaskMetaSize).set(metaBytes);
    outRestoredPtrPtr = wasm.aifw_malloc(4);
    const rcRestore = wasm.aifw_session_restore_with_meta(session.handle, zigMaskedText.ptr, zigMaskMetaPtr, outRestoredPtrPtr);
    if (rcRestore !== 0) throw new Error(`restore failed rc=${rcRestore}`);
    const restoredPtr = new DataView(wasm.memory.buffer).getUint32(outRestoredPtrPtr, true);
    const restoredStr = restoredPtr ? readZigStr(restoredPtr) : '';
    // free restored core string after copying out (if non-null)
    if (restoredPtr) wasm.aifw_string_free(restoredPtr);
    return restoredStr;
  } finally {
    if (outRestoredPtrPtr) freeBuf(outRestoredPtrPtr, 4);
    if (zigMaskedText) freeBuf(zigMaskedText.ptr, zigMaskedText.size);
    // Note: serialized zigMaskMetaPtr is freed by core during restore_with_meta
  }
}

// Batch mask: inputs can be array of strings or { text, language }
export async function maskTextBatch(textAndLanguageArray) {
  if (!Array.isArray(textAndLanguageArray)) throw new Error('maskTextBatch: textAndLanguageArray must be an array');
  const tasks = textAndLanguageArray.map((it) => {
    const { text, language } = it || {};
    return maskText(String(text || ''), language);
  });
  const results = await Promise.all(tasks);
  return results.map(([masked, maskMeta]) => ({ text: masked, maskMeta }));
}

// Batch restore: items = array of { text: maskedText, maskMeta }
export async function restoreTextBatch(textAndMaskMetaArray) {
  if (!Array.isArray(textAndMaskMetaArray)) throw new Error('restoreTextBatch: textAndMaskMetaArray must be an array');
  const tasks = textAndMaskMetaArray.map((it) => {
    const obj = it || {};
    return restoreText(String(obj.text || ''), obj.maskMeta);
  });
  const results = await Promise.all(tasks);
  return results.map((restored) => ({ text: restored }));
}

export async function getPiiSpans(inputText, language) {
  if (!wasm || !session?.handle) throw new Error('invalid session handle');
  const nerPipe = selectNer(language);
  if (!nerPipe) throw new Error('NER pipeline not ready');

  let zigInputText = null;
  let nerBuf = null;
  let outSpansPtrPtr = 0;
  let outCountPtr = 0;
  try {
    zigInputText = allocZigStrFromJs(inputText);
    const items = await nerPipe.run(inputText);
    nerBuf = nerLib.buildNerEntitiesBuffer(wasm, items, inputText);

    outSpansPtrPtr = wasm.aifw_malloc(4);
    outCountPtr = wasm.aifw_malloc(4);
    const rc = wasm.aifw_session_get_pii_spans(session.handle, zigInputText.ptr, nerBuf.ptr, nerBuf.count >>> 0, outSpansPtrPtr, outCountPtr);
    if (rc !== 0) throw new Error(`get_pii_spans failed rc=${rc}`);
    const dv = new DataView(wasm.memory.buffer);
    const spansPtr = dv.getUint32(outSpansPtrPtr, true);
    const count = dv.getUint32(outCountPtr, true);
    // Layout (extern struct): u32 entity_id, u8 entity_type, 3-byte padding, u32 matched_start, u32 matched_end
    const spanSize = 4 + 1 + 3 + 4 + 4; // 16 bytes
    // Read as raw bytes and parse
    const spanBytes = new Uint8Array(wasm.memory.buffer, spansPtr, count * spanSize);
    const res = [];
    const dvSpan = new DataView(spanBytes.buffer, spanBytes.byteOffset, spanBytes.byteLength);
    for (let i = 0; i < count; i++) {
      const base = i * spanSize;
      const entity_id = dvSpan.getUint32(base + 0, true);
      const entity_type = dvSpan.getUint8(base + 4);
      const matched_start = dvSpan.getUint32(base + 8, true);
      const matched_end = dvSpan.getUint32(base + 12, true);
      res.push(new MatchedPIISpan(entity_id, entity_type, matched_start, matched_end));
    }
    // Free spans buffer allocated by aifw core
    if (spansPtr && count) freeBuf(spansPtr, count * spanSize);
    // aifw core may free spans later; caller only reads
    return res;
  } finally {
    if (outSpansPtrPtr) freeBuf(outSpansPtrPtr, 4);
    if (outCountPtr) freeBuf(outCountPtr, 4);
    if (nerBuf?.ptr) freeBuf(nerBuf.ptr, nerBuf.byteSize);
    if (nerBuf?.owned) for (const s of nerBuf.owned) freeBuf(s.ptr, s.size);
    if (zigInputText) freeBuf(zigInputText.ptr, zigInputText.size);
  }
}
