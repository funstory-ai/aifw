let wasm = null;
let nerLib = null;
let ner = null;

// Helpers
function allocZstrFromJs(str) {
  const enc = new TextEncoder();
  const bytes = enc.encode(str || '');
  const buf = new Uint8Array(bytes.length + 1);
  buf.set(bytes, 0);
  buf[bytes.length] = 0;
  const ptr = wasm.aifw_malloc(buf.length);
  if (!ptr) throw new Error('aifw_malloc failed');
  new Uint8Array(wasm.memory.buffer, ptr, buf.length).set(buf);
  return { ptr, size: buf.length };
}

function readZstr(ptr) {
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
  const resp = await fetch(urlStr);
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
  // wire wasm exports from host or auto-load
  wasm = await loadAifwCore(wasmBase);
  // load NER lib and pipeline (relative import for packaged lib)
  nerLib = await import('./libner.js');

  // Force SIMD on, and set threads from hardwareConcurrency (>=1)
  const threads = (typeof navigator !== 'undefined' && navigator.hardwareConcurrency) ? Math.max(1, navigator.hardwareConcurrency) : 1;
  nerLib.initEnv({ wasmBase, modelsBase, threads, simd: true });

  const modelId = 'funstory-ai/neurobert-mini';
  ner = await nerLib.buildNerPipeline(modelId, { quantized: true });
}

export async function deinit() {
  wasm.aifw_shutdown();
  // nothing special; GC will collect JS objects
  ner = null;
  nerLib = null;
  wasm = null;
}

export async function createSession() {
  if (!wasm) throw new Error('AIFW not initialized');
  // default ner_recog_type = token_classification (0)
  const initBuf = new Uint8Array(4);
  const initAlloc = wasm.aifw_malloc(initBuf.length);
  new Uint8Array(wasm.memory.buffer, initAlloc, initBuf.length).set(initBuf);
  new DataView(wasm.memory.buffer).setUint32(initAlloc + 0, 0, true);

  let sess = {};
  try {
    sess.handle = wasm.aifw_session_create(initAlloc);
    if (!sess.handle) throw new Error('session_create failed');
  } finally {
    // init buffer can be freed immediately after creation
    freeBuf(initAlloc, initBuf.length);
  }
  sess.zig_text = null;
  return sess;
}

export async function destroySession(sess) {
  if (!wasm || !sess?.handle) throw new Error('invalid session handle');
  try {
    wasm.aifw_session_destroy(sess.handle);
  } finally {
    sess.handle = 0;
    if (sess.zig_text) {
      freeBuf(sess.zig_text.ptr, sess.zig_text.size);
      sess.zig_text = null;
    }
  }
}

export async function maskText(sess, inputText) {
  if (!wasm || !sess?.handle) throw new Error('invalid session handle');
  if (!ner) throw new Error('NER pipeline not ready');

  if (sess.zig_text) {
    freeBuf(sess.zig_text.ptr, sess.zig_text.size);
    sess.zig_text = null;
  }
  let nerBuf = null;
  let outMaskedPtrPtr = 0;
  try {
    sess.zig_text = allocZstrFromJs(inputText);
    const items = await ner.run(inputText);
    nerBuf = nerLib.buildNerEntitiesBuffer(wasm, items, inputText.length);

    outMaskedPtrPtr = wasm.aifw_malloc(4);
    const rcMask = wasm.aifw_session_mask(sess.handle, sess.zig_text.ptr, nerBuf.ptr, nerBuf.count >>> 0, outMaskedPtrPtr);
    if (rcMask !== 0) throw new Error(`mask failed rc=${rcMask}`);
    const maskedPtr = new DataView(wasm.memory.buffer).getUint32(outMaskedPtrPtr, true);
    const maskedStr = readZstr(maskedPtr);
    // free masked core string after copying out
    wasm.aifw_string_free(maskedPtr);
    return maskedStr;
  } finally {
    if (outMaskedPtrPtr) freeBuf(outMaskedPtrPtr, 4);
    if (nerBuf?.ptr) freeBuf(nerBuf.ptr, nerBuf.byteSize);
    if (nerBuf?.owned) for (const s of nerBuf.owned) freeBuf(s.ptr, s.size);
  }
}

export async function restoreText(sess, maskedText) {
  if (!wasm || !sess?.handle) throw new Error('invalid session');

  let wasmMaskedText = null;
  let outRestoredPtrPtr = 0;
  try {
    wasmMaskedText = allocZstrFromJs(maskedText);
    outRestoredPtrPtr = wasm.aifw_malloc(4);
    const rcRestore = wasm.aifw_session_restore(sess.handle, wasmMaskedText.ptr, outRestoredPtrPtr);
    if (rcRestore !== 0) throw new Error(`restore failed rc=${rcRestore}`);
    const restoredPtr = new DataView(wasm.memory.buffer).getUint32(outRestoredPtrPtr, true);
    const restoredStr = readZstr(restoredPtr);
    // free restored core string after copying out
    wasm.aifw_string_free(restoredPtr);
    return restoredStr;
  } finally {
    if (outRestoredPtrPtr) freeBuf(outRestoredPtrPtr, 4);
    if (wasmMaskedText) freeBuf(wasmMaskedText.ptr, wasmMaskedText.size);
  }
}
