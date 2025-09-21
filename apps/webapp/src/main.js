const statusEl = document.getElementById('status');
const textEl = document.getElementById('text');
const maskedEl = document.getElementById('masked');
const restoredEl = document.getElementById('restored');
const runBtn = document.getElementById('run');

let wasm; // wasm instance exports

// Minimal imports with js_log for Zig std.log
const imports = {
  env: {
    js_log(level, ptr, len) {
      try {
        const bytes = new Uint8Array(wasm.memory.buffer, ptr, len);
        const msg = new TextDecoder().decode(bytes);
        const tag = ["ERR", "WRN", "INF", "DBG"][level] || "LOG";
        console.log(`[aifw_core:${tag}]`, msg);
      } catch (_) {}
    },
  },
};

async function loadWasm() {
  statusEl.textContent = 'Loading core...';
  // wasm is served from public/wasm
  const resp = await fetch('/wasm/liboneaifw_core.wasm');
  if (!resp.ok) throw new Error(`fetch wasm failed: ${resp.status}`);
  const bytes = await resp.arrayBuffer();
  const { instance } = await WebAssembly.instantiate(bytes, imports);
  wasm = instance.exports;
  statusEl.textContent = 'Core loaded.';
  if (!wasm.aifw_malloc || !wasm.aifw_free_sized) {
    console.warn('alloc exports missing; available exports:', Object.keys(wasm));
  }
}

function allocZstrFromJs(str) {
  const enc = new TextEncoder();
  const bytes = enc.encode(str);
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

async function main() {
  await loadWasm();

  runBtn.addEventListener('click', () => {
    try {
      statusEl.textContent = 'Running...';
      maskedEl.textContent = '';
      restoredEl.textContent = '';

      // Create session (default ner_recog_type = token_classification)
      const initBuf = new Uint8Array(4);
      const initAlloc = wasm.aifw_malloc(initBuf.length);
      new Uint8Array(wasm.memory.buffer, initAlloc, initBuf.length).set(initBuf);
      new DataView(wasm.memory.buffer).setUint32(initAlloc + 0, 0, true);

      const sess = wasm.aifw_session_create(initAlloc);
      if (!sess) throw new Error('session_create failed');

      // Prepare input text
      const textStr = textEl.value || '';
      const text = allocZstrFromJs(textStr);

      // Call mask (no external NER: pass empty slice)
      const outMaskedPtrPtr = wasm.aifw_malloc(4);
      const rcMask = wasm.aifw_session_mask(sess, text.ptr, 0, 0, outMaskedPtrPtr);
      if (rcMask !== 0) throw new Error(`mask failed rc=${rcMask}`);
      const maskedPtr = new DataView(wasm.memory.buffer).getUint32(outMaskedPtrPtr, true);
      const maskedStr = readZstr(maskedPtr);
      maskedEl.textContent = maskedStr;

      // Call restore
      const outRestoredPtrPtr = wasm.aifw_malloc(4);
      const rcRestore = wasm.aifw_session_restore(sess, maskedPtr, outRestoredPtrPtr);
      if (rcRestore !== 0) throw new Error(`restore failed rc=${rcRestore}`);
      const restoredPtr = new DataView(wasm.memory.buffer).getUint32(outRestoredPtrPtr, true);
      const restoredStr = readZstr(restoredPtr);
      restoredEl.textContent = restoredStr;

      // Cleanup
      wasm.aifw_string_free(maskedPtr);
      wasm.aifw_string_free(restoredPtr);
      freeBuf(outMaskedPtrPtr, 4);
      freeBuf(outRestoredPtrPtr, 4);
      freeBuf(text.ptr, text.size);
      freeBuf(initAlloc, initBuf.length);
      wasm.aifw_session_destroy(sess);

      statusEl.textContent = 'Done';
    } catch (e) {
      statusEl.textContent = `Error: ${e.message || e}`;
    }
  });
}

main().catch((e) => statusEl.textContent = `Error: ${e.message || e}`);
