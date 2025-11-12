let session = null;
let wasm = null;
let nerLib = null;
let nerPipelines = {
  default: null,
  zh: null,
};

import { sha3_256 as sha3_256_fn } from 'js-sha3';

// Lazy OpenCC converters (Simplified <-> Traditional)
let openccConverters = { s2t: null, t2s: null };
// Small LRU caches for conversions to avoid repeated s2t/t2s on same text
const OPENCC_CACHE_LIMIT = 32;
const openccCache = { s2t: new Map(), t2s: new Map() };
function cacheGet(map, key) { return map.get(key); }
function cacheSet(map, key, val) {
  if (map.size >= OPENCC_CACHE_LIMIT && !map.has(key)) {
    // delete the first inserted key
    const it = map.keys().next();
    if (!it.done) map.delete(it.value);
  }
  map.set(key, val);
}
async function s2tCached(text) {
  const hit = cacheGet(openccCache.s2t, text);
  if (hit !== undefined) return hit;
  const { s2t } = await ensureOpenCC();
  const out = s2t(text);
  cacheSet(openccCache.s2t, text, out);
  return out;
}
async function t2sCached(text) {
  const hit = cacheGet(openccCache.t2s, text);
  if (hit !== undefined) return hit;
  const { t2s } = await ensureOpenCC();
  const out = t2s(text);
  cacheSet(openccCache.t2s, text, out);
  return out;
}
function t2sCachedSync(text) { // best-effort if ensureOpenCC already loaded
  if (!openccConverters.t2s) return text;
  const hit = cacheGet(openccCache.t2s, text);
  if (hit !== undefined) return hit;
  const out = openccConverters.t2s(text);
  cacheSet(openccCache.t2s, text, out);
  return out;
}
async function ensureOpenCC() {
  if (openccConverters.s2t && openccConverters.t2s) return openccConverters;
  try {
    const mod = await import('opencc-js');
    const OpenCC = mod?.default || mod;
    const s2t = await OpenCC.Converter({ from: 'cn', to: 'tw' });
    const t2s = await OpenCC.Converter({ from: 'tw', to: 'cn' });
    openccConverters = { s2t, t2s };
  } catch (e) {
    console.warn('[aifw] opencc-js not available, fallback to identity conversion', e);
    openccConverters = { s2t: (s) => s, t2s: (s) => s };
  }
  return openccConverters;
}

function isZhSimplified(language) {
  const lang = String(language || '').toLowerCase();
  if (lang === 'zh') return true; // legacy -> treat as zh-cn
  if (lang === 'zh-cn') return true;
  if (!lang.startsWith('zh-')) return false;
  if (lang.includes('hant')) return false;
  if (lang.includes('tw')) return false;
  if (lang.includes('hk')) return false;
  return true;
}

// -------- Language detection (heuristic-first, OpenCC on-demand) --------
function ratioOfHan(text) {
  if (!text) return 0;
  let han = 0, total = 0;
  for (let i = 0; i < text.length;) {
    const cp = text.codePointAt(i);
    const cu = cp > 0xFFFF ? 2 : 1;
    total += 1;
    // Basic CJK + Extension A + Compatibility Ideographs
    if ((cp >= 0x4E00 && cp <= 0x9FFF) || (cp >= 0x3400 && cp <= 0x4DBF) || (cp >= 0xF900 && cp <= 0xFAFF)) han += 1;
    i += cu;
  }
  return total ? han / total : 0;
}
function ratioOfLatin(text) {
  if (!text) return 0;
  let lat = 0, total = 0;
  for (let i = 0; i < text.length; i++) {
    const ch = text.charCodeAt(i);
    total += 1;
    if ((ch >= 0x41 && ch <= 0x5A) || (ch >= 0x61 && ch <= 0x7A)) lat += 1;
  }
  return total ? lat / total : 0;
}
function quickLang(text) {
  const han = ratioOfHan(text);
  const lat = ratioOfLatin(text);
  // The threshold 0.3 for han and 0.5 for lat can be finetuned based on specific use cases.
  if (han >= 0.3) return 'zh';
  if (lat >= 0.5) return 'en';
  return 'other';
}
// Expanded heuristics: simplified/traditional unique chars and words
const SIMPLIFIED_ONLY = new Set([
  '后','发','台','里','复','面','余','划','钟','观','厂','广','圆','国','东','乐','云','内','两',
  '丢','为','价','众','优','冲','况','刘','师','于','亏','仅','从','兴','举','义','乌','专'
]);
const TRADITIONAL_ONLY = new Set([
  '後','發','臺','裡','複','麵','餘','劃','鐘','觀','廠','廣','圓','國','東','樂','雲','內','兩',
  '丟','為','價','眾','優','衝','況','劉','師','於','虧','僅','從','興','舉','義','烏','專'
]);
const SIMPLIFIED_WORDS = ['开发','软件','后端','互联网','应用','运维','里程','联系','台阶','复用'];
const TRADITIONAL_WORDS = ['開發','軟體','後端','網際網路','應用','運維','聯繫','臺階','複用'];
function scoreBySets(text) {
  let sScore = 0, tScore = 0;
  for (const ch of text) {
    if (SIMPLIFIED_ONLY.has(ch)) sScore++;
    if (TRADITIONAL_ONLY.has(ch)) tScore++;
  }
  for (const w of SIMPLIFIED_WORDS) if (text.includes(w)) sScore += 2;
  for (const w of TRADITIONAL_WORDS) if (text.includes(w)) tScore += 2;
  return { sScore, tScore };
}
function quickScriptZh(text) {
  const { sScore, tScore } = scoreBySets(text);
  if (sScore - tScore >= 2) return 'Hans';
  if (tScore - sScore >= 2) return 'Hant';
  return null;
}
function diffRatio(a, b) {
  if (a === b) return 0;
  const n = Math.min(a.length, b.length);
  let diff = Math.abs(a.length - b.length);
  for (let i = 0; i < n; i++) if (a[i] !== b[i]) diff++;
  return n ? diff / Math.max(a.length, b.length) : 1;
}
async function decideScriptWithOpenCC(text) {
  const toT = await s2tCached(text);
  const toS = await t2sCached(text);
  const sChanged = toT !== text;
  const tChanged = toS !== text;
  if (sChanged && !tChanged) return 'Hans';
  if (!sChanged && tChanged) return 'Hant';
  const diffS = diffRatio(text, toS);
  const diffT = diffRatio(text, toT);
  return diffS <= diffT ? 'Hans' : 'Hant';
}
export async function detectLanguage(text) {
  const lang = quickLang(text || '');
  if (lang !== 'zh') return { lang, script: null, confidence: lang === 'en' ? 0.9 : 0.6, method: 'heuristic' };
  const scriptQuick = quickScriptZh(text || '');
  if (scriptQuick) return { lang: 'zh', script: scriptQuick, confidence: 0.8, method: 'heuristic' };
  const script = await decideScriptWithOpenCC(text || '');
  return { lang: 'zh', script, confidence: 0.95, method: 'opencc' };
}

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

async function loadAifwCore() {
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
  const urlStr = new URL(/* @vite-ignore */ './wasm/liboneaifw_core.wasm', import.meta.url).toString();
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

const ASSETS_BASE_MANAGED_GITHUB = 'https://raw.githubusercontent.com/funstory-ai/OneAIFW-Assets/main/';
const ASSETS_BASE_MANAGED_HF = 'https://huggingface.co/immersiveL/OneAIFW-Assets/resolve/main/';
const ASSETS_BASE_MANAGED_MODEL_SCOPE = 'https://www.modelscope.cn/models/awwaawwa/OneAIFW-Assets/files/';

const OneAIFW_ASSETS_VERSION = '0.3.1';

const DEFAULT_MODELS_SUBDIR = 'models/';
const DEFAULT_OVERALL_MODE = 'managed';
const DEFAULT_MODELS_MODE = 'managed';
const DEFAULT_ORT_MODE = 'managed';

const DEFAULT_EN_MODEL_ID = 'funstory-ai/neurobert-mini';
const EN_MODEL_SHA3_256 = '0xa7c4bfc5e2b7cfdfce2012b38e6eca712b433c4ed47ffc973ee9e3964056834a';
const DEFAULT_ZH_MODEL_ID = 'ckiplab/bert-tiny-chinese-ner';
const ZH_MODEL_SHA3_256 = '0x0d723d495d0365236e12e51abbcb97407e8d1f51ec3154656e9267de31fc9ce6';

const DEFAULT_WASM_SUBDIR = 'wasm/';
const DEFAULT_ORT_NAME = 'ort-wasm-simd.wasm';
const DEFAULT_THREADS = 1;
const DEFAULT_SIMD = true;
const ORT_WASM_SHA3_256 = '0x0c1482593eb573d11e6e6c5539cf5436a323e4d49b843135317f053ab0523277';

function compareVersion(a, b) {
  const pa = String(a || '').split('.').map((x) => parseInt(x, 10) || 0);
  const pb = String(b || '').split('.').map((x) => parseInt(x, 10) || 0);
  const len = Math.max(pa.length, pb.length);
  for (let i = 0; i < len; i++) {
    const va = pa[i] || 0;
    const vb = pb[i] || 0;
    if (va > vb) return 1;
    if (va < vb) return -1;
  }
  return 0;
}

async function computeSha3_256Hex(buffer) {
  const bytes = buffer instanceof ArrayBuffer ? new Uint8Array(buffer) : (buffer instanceof Uint8Array ? buffer : new Uint8Array(buffer));
  const hasher = sha3_256_fn.create();
  hasher.update(bytes);
  const hex = hasher.hex();
  return '0x' + hex;
}

async function fetchWithCache(url, cacheName) {
  try {
    if (typeof caches !== 'undefined' && caches?.open) {
      const cache = await caches.open(cacheName);
      let resp = await cache.match(url);
      if (resp && resp.ok) return resp.clone();
      resp = await fetch(url, { cache: 'no-store' });
      if (!resp.ok) throw new Error(`fetch ${url} failed: ${resp.status}`);
      await cache.put(url, resp.clone());
      return resp.clone();
    }
  } catch (e) {
    console.warn('[aifw-js] CacheStorage not available or failed, fallback to network', e);
  }
  const resp = await fetch(url, { cache: 'no-store' });
  if (!resp.ok) throw new Error(`fetch ${url} failed: ${resp.status}`);
  return resp;
}

async function ensureManagedAssetsAvailable({ assetsBase, enModelId, zhModelId, ortName }) {
  const helloUrl = assetsBase + 'hello.json';
  const helloResp = await fetchWithCache(helloUrl, 'oneaifw-assets');
  const hello = await helloResp.json().catch(() => ({}));
  const remoteVersion = String(hello?.version || '');
  if (!remoteVersion) throw new Error('[aifw-js] invalid assets source: missing version in hello.json');
  if (compareVersion(OneAIFW_ASSETS_VERSION, remoteVersion) > 0) {
    throw new Error(`[aifw-js] assets version too old: required<=${OneAIFW_ASSETS_VERSION}, got ${remoteVersion}`);
  }
  const cacheName = `oneaifw-assets-v${remoteVersion}`;

  // Validate EN model
  const enOnnxUrl = assetsBase + `${DEFAULT_MODELS_SUBDIR}${enModelId}/onnx/model_quantized.onnx`;
  const enOnnxResp = await fetchWithCache(enOnnxUrl, cacheName);
  const enOnnxBuf = await enOnnxResp.arrayBuffer();
  const enHash = await computeSha3_256Hex(enOnnxBuf);
  if (EN_MODEL_SHA3_256 && enHash.toLowerCase() !== EN_MODEL_SHA3_256.toLowerCase()) {
    throw new Error(`[aifw-js] EN model hash mismatch: got ${enHash}, expected ${EN_MODEL_SHA3_256}`);
  }

  // Validate ZH model
  const zhOnnxUrl = assetsBase + `${DEFAULT_MODELS_SUBDIR}${zhModelId}/onnx/model_quantized.onnx`;
  const zhOnnxResp = await fetchWithCache(zhOnnxUrl, cacheName);
  const zhOnnxBuf = await zhOnnxResp.arrayBuffer();
  const zhHash = await computeSha3_256Hex(zhOnnxBuf);
  if (ZH_MODEL_SHA3_256 && zhHash.toLowerCase() !== ZH_MODEL_SHA3_256.toLowerCase()) {
    throw new Error(`[aifw-js] ZH model hash mismatch: got ${zhHash}, expected ${ZH_MODEL_SHA3_256}`);
  }

  // Validate ORT wasm
  const ortUrl = assetsBase + `${DEFAULT_WASM_SUBDIR}${ortName}`;
  const ortResp = await fetchWithCache(ortUrl, cacheName);
  const ortBuf = await ortResp.arrayBuffer();
  const ortHash = await computeSha3_256Hex(ortBuf);
  if (ORT_WASM_SHA3_256 && ortHash.toLowerCase() !== ORT_WASM_SHA3_256.toLowerCase()) {
    throw new Error(`[aifw-js] ORT wasm hash mismatch: got ${ortHash}, expected ${ORT_WASM_SHA3_256}`);
  }

  return { remoteVersion, cacheName };
}

async function pickFastestAssetsBase() {
  const candidates = [
    ASSETS_BASE_MANAGED_HF,
    ASSETS_BASE_MANAGED_GITHUB,
    ASSETS_BASE_MANAGED_MODEL_SCOPE,
  ];
  const tasks = candidates.map((base) => (async () => {
    const url = base + 'hello.json';
    const r = await fetch(url, { cache: 'no-store' });
    if (!r.ok) throw new Error(`hello.json not ok from ${url}: ${r.status}`);
    await r.json().catch(() => { throw new Error(`invalid hello.json from ${url}`); });
    return base;
  })());
  try {
    return await Promise.any(tasks);
  } catch (_) {
    throw new Error('[aifw-js] all managed asset sources failed for hello.json');
  }
}

export async function init(options = {}) {
  // Backward compatibility: map legacy options to new structure
  // Legacy: { wasmBase, modelsBase }
  let legacyWasmBase = options.wasmBase;
  let legacyModelsBase = options.modelsBase;

  // New options (modes can be chosen separately per resource group)
  // {
  //   mode?: 'managed' | 'customize',
  //   models?: { mode?: 'managed'|'customize', modelsBase?: string, enModelId?: string, zhModelId?: string },
  //   ort?: { mode?: 'managed'|'customize', wasmBase?: string, ortName?: string, threads?: number, simd?: boolean }
  // }
  const overallMode = options.mode || DEFAULT_OVERALL_MODE;
  const modelsCfg = options.models || { mode: DEFAULT_MODELS_MODE };
  const ortCfg = options.ort || { mode: DEFAULT_ORT_MODE };

  if (overallMode === 'managed' && (legacyWasmBase || legacyModelsBase)) {
    console.warn('[aifw-js] mode=managed is not compatible with legacy wasmBase or modelsBase, ignoring legacy settings.');
    legacyWasmBase = undefined;
    legacyModelsBase = undefined;
  }
  if (overallMode === 'managed' && (modelsCfg.mode === 'customize' || ortCfg.mode === 'customize')) {
    console.warn('[aifw-js] mode=managed is not compatible with customize mode, ignoring customize settings.');
    modelsCfg.mode = 'managed';
    ortCfg.mode = 'managed';
  }

  // Determine effective modes
  const modelsMode = modelsCfg.mode || overallMode || (legacyModelsBase ? 'customize' : 'managed');
  const ortMode = ortCfg.mode || overallMode || (legacyWasmBase ? 'customize' : 'managed');

  // Derive effective paths/settings
  // ORT runtime wasm base (onnxruntime-web wasm files)
  let ortWasmBase = ortCfg.wasmBase;
  const ortName = ortMode === 'managed' ? DEFAULT_ORT_NAME : (ortCfg.ortName || DEFAULT_ORT_NAME);
  const threads = ortMode === 'managed' ? DEFAULT_THREADS : (ortCfg.threads || DEFAULT_THREADS);
  const simd = ortMode === 'managed' ? DEFAULT_SIMD : (ortCfg.simd || DEFAULT_SIMD);

  // Validate customize wasm base for ORT
  if (ortMode === 'customize' && !ortWasmBase) {
    throw new Error('[aifw-js] ort.mode=customize requires ort.wasmBase');
  }

  // Models base directory (used for local/customize)
  let modelsBase = modelsCfg.modelsBase;
  const enModelId = modelsMode === 'managed' ? DEFAULT_EN_MODEL_ID : (modelsCfg.enModelId || DEFAULT_EN_MODEL_ID);
  const zhModelId = modelsMode === 'managed' ? DEFAULT_ZH_MODEL_ID : (modelsCfg.zhModelId || DEFAULT_ZH_MODEL_ID);

  // Validate customize models base for NER
  if (modelsMode === 'customize' && !modelsBase) {
    throw new Error('[aifw-js] models.mode=customize requires models.modelsBase');
  }

  let cacheNameForFetch = null;
  if (modelsMode === 'managed' || ortMode === 'managed') {
    const assetsBase = await pickFastestAssetsBase();
    if (modelsMode === 'managed') modelsBase = assetsBase + DEFAULT_MODELS_SUBDIR;
    if (ortMode === 'managed') ortWasmBase = assetsBase + DEFAULT_WASM_SUBDIR;
    const { cacheName } = await ensureManagedAssetsAvailable({
      assetsBase,
      enModelId,
      zhModelId,
      ortName,
    });
    cacheNameForFetch = cacheName;
  }

  console.info('[aifw-js] modelsBase:', modelsBase);
  console.info('[aifw-js] ortWasmBase:', ortWasmBase);
  console.info('[aifw-js] cacheNameForFetch:', cacheNameForFetch);

  // Load aifw core wasm library (separate from ORT wasm)
  wasm = await loadAifwCore();
  // load NER lib and pipeline (relative import for packaged lib)
  nerLib = await import('./libner.js');

  // Initialize NER/Transformers env for ORT and models
  // default mode: do not set explicit paths (let library/CDN manage)
  // local/customize: user-managed paths
  const initEnvArgs = {};
  initEnvArgs.wasmBase = ortWasmBase;
  initEnvArgs.modelsBase = modelsBase;
  initEnvArgs.threads = threads;
  initEnvArgs.simd = simd;
  if (cacheNameForFetch) {
    initEnvArgs.fetchFn = (url, opts) => fetchWithCache(url, cacheNameForFetch);
  }
  nerLib.initEnv(initEnvArgs);

  // Preload NER pipelines for EN(default) and ZH
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
    console.log('[aifw-js] select zh NER pipeline.');
    return nerPipelines.zh || nerPipelines.default;
  }
  console.log('[aifw-js] select en NER pipeline.', nerPipelines.default);
  return nerPipelines.default;
}

export async function maskText(inputText, language) {
  if (!wasm || !session?.handle) throw new Error('invalid session handle');
  let langToUse = language;
  if (langToUse == null || langToUse === '' || langToUse === 'auto') {
    const det = await detectLanguage(inputText || '');
    if (det.lang === 'zh') langToUse = det.script === 'Hant' ? 'zh-TW' : 'zh-CN'; else langToUse = det.lang || 'en';
  }
  const nerPipe = selectNer(langToUse);
  if (!nerPipe) throw new Error('NER pipeline not ready');

  let zigInputText = null;
  let nerBuf = null;
  let outMaskedPtrPtr = 0;
  let outMaskMetaPtrPtr = 0;
  try {
    zigInputText = allocZigStrFromJs(inputText);
    let runText = inputText;
    let runOpts = undefined;
    if (nerPipe === nerPipelines.zh && isZhSimplified(langToUse)) {
      runText = await s2tCached(inputText);
      // Bind cached t2s for token transform (sync if already loaded)
      const tokenT2S = (s) => t2sCachedSync(s);
      runOpts = { offsetText: inputText, tokenTransform: tokenT2S };
    }
    const items = await nerPipe.run(runText, runOpts);
    nerBuf = nerLib.buildNerEntitiesBuffer(wasm, items, inputText);

    outMaskedPtrPtr = wasm.aifw_malloc(4);
    outMaskMetaPtrPtr = wasm.aifw_malloc(4);
    const langEnum = (() => {
      const l = String(langToUse || '').toLowerCase();
      if (l.startsWith('en')) return 1; // Language.en
      if (l.startsWith('ja')) return 2; // Language.ja
      if (l.startsWith('ko')) return 3; // Language.ko
      if (l === 'zh') return 4; // Language.zh
      if (l === 'zh-cn') return 5; // Language.zh_cn
      if (l === 'zh-tw') return 6; // Language.zh_tw
      if (l === 'zh-hk') return 7; // Language.zh_hk
      if (l === 'zh-hans') return 8; // Language.zh_hans
      if (l === 'zh-hant') return 9; // Language.zh_hant
      if (l.startsWith('fr')) return 10; // Language.fr
      if (l.startsWith('de')) return 11; // Language.de
      if (l.startsWith('ru')) return 12; // Language.ru
      if (l.startsWith('es')) return 13; // Language.es
      if (l.startsWith('it')) return 14; // Language.it
      if (l.startsWith('ar')) return 15; // Language.ar
      if (l.startsWith('pt')) return 16; // Language.pt
      return 0; // Unknown
    })();
    const rcMask = wasm.aifw_session_mask_and_out_meta(session.handle, zigInputText.ptr, nerBuf.ptr, nerBuf.count >>> 0, langEnum >>> 0, outMaskedPtrPtr, outMaskMetaPtrPtr);
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
  const tasks = textAndLanguageArray.map(async (it) => {
    if (typeof it === 'string') return maskText(String(it || ''), null);
    const { text, language } = it || {};
    const lang = (language == null || language === '' || language === 'auto') ? null : language;
    return maskText(String(text || ''), lang);
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
  let langToUse = language;
  if (langToUse == null || langToUse === '' || langToUse === 'auto') {
    const det = await detectLanguage(inputText || '');
    if (det.lang === 'zh') langToUse = det.script === 'Hant' ? 'zh-TW' : 'zh-CN'; else langToUse = det.lang || 'en';
  }
  const nerPipe = selectNer(langToUse);
  if (!nerPipe) throw new Error('NER pipeline not ready');

  let zigInputText = null;
  let nerBuf = null;
  let outSpansPtrPtr = 0;
  let outCountPtr = 0;
  try {
    zigInputText = allocZigStrFromJs(inputText);
    let runText = inputText;
    let runOpts = undefined;
    if (nerPipe === nerPipelines.zh && isZhSimplified(langToUse)) {
      runText = await s2tCached(inputText);
      const tokenT2S = (s) => t2sCachedSync(s);
      runOpts = { offsetText: inputText, tokenTransform: tokenT2S };
    }
    const items = await nerPipe.run(runText, runOpts);
    nerBuf = nerLib.buildNerEntitiesBuffer(wasm, items, inputText);

    outSpansPtrPtr = wasm.aifw_malloc(4);
    outCountPtr = wasm.aifw_malloc(4);
    const langEnum = (() => {
      const l = String(langToUse || '').toLowerCase();
      if (l.startsWith('zh')) return 1; // Language.ZH
      if (l.startsWith('en')) return 2; // Language.EN
      return 0; // Unknown
    })();
    const rc = wasm.aifw_session_get_pii_spans(session.handle, zigInputText.ptr, nerBuf.ptr, nerBuf.count >>> 0, langEnum >>> 0, outSpansPtrPtr, outCountPtr);
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
