import fs from 'node:fs'
import fsp from 'node:fs/promises'
import path from 'node:path'
import https from 'node:https'
import { spawn } from 'node:child_process'
import { HttpsProxyAgent } from 'https-proxy-agent'

const ROOT = path.resolve(process.cwd())
const PUBLIC_DIR = path.join(ROOT, 'public')
const MODELS_DIR = path.join(PUBLIC_DIR, 'models')
const TOOLS_DIR = path.resolve(ROOT, '..', '..', 'tools')
const WASM_PUBLIC_DIR = path.join(PUBLIC_DIR, 'wasm')
const WASM_NODE_DIR = path.join(ROOT, 'node_modules', '@xenova', 'transformers', 'dist')

// CLI/env flags
const argv = new Set(process.argv.slice(2))
const ALLOW_REMOTE = argv.has('--allow-remote') || process.env.ALLOW_REMOTE === '1'
const STRICT = argv.has('--strict') || process.env.STRICT_MODE === '1'
const OFFLINE = argv.has('--offline') || !ALLOW_REMOTE

// Proxy support for corporate/filtered networks
const PROXY_URL = process.env.HTTPS_PROXY || process.env.https_proxy || process.env.HTTP_PROXY || process.env.http_proxy || null
const HTTPS_AGENT = PROXY_URL ? new HttpsProxyAgent(PROXY_URL) : undefined
const HF_ENDPOINT = process.env.HF_ENDPOINT || null
const HF_TOKEN = process.env.HF_TOKEN || null

// For each model, define core files and tokenizer alternatives
// Optional fields per model:
// - remoteBaseToken: override base URL for tokenizer files
// - remoteBaseConfig: override base URL for config/extra files
// - remoteBaseOnnx: override base URL for onnx files
// - exportFrom: HF repo id to use when exporting ONNX via Python
const SUPPORTED = [
  // {
  //   id: 'Xenova/bert-base-NER',
  //   core: [
  //     'config.json',
  //     'onnx/model_quantized.onnx',
  //   ],
  //   tokenizerAlt: [
  //     'tokenizer.json',
  //     'vocab.txt',
  //   ],
  //   extra: [
  //     'tokenizer_config.json',
  //   ],
  //   remoteBase: 'https://huggingface.co/Xenova/bert-base-NER/resolve/main/',
  // },
  {
    id: 'Xenova/distilbert-base-cased-finetuned-conll03-english',
    core: [
      'config.json',
      'onnx/model_quantized.onnx',
    ],
    tokenizerAlt: [
      // preferred fast tokenizer
      'tokenizer.json',
      // fallback for BERT WordPiece
      'vocab.txt',
    ],
    extra: [
      // helps AutoTokenizer select correct preprocessor when using vocab.txt
      'tokenizer_config.json',
    ],
    // Xenova repo may lack some files; use base DistilBERT repo for tokenizer/config, and export ONNX from dslim's NER
    remoteBase: 'https://huggingface.co/Xenova/distilbert-base-cased-finetuned-conll03-english/resolve/main/',
    remoteBaseToken: 'https://huggingface.co/distilbert-base-cased/resolve/main/',
    remoteBaseConfig: 'https://huggingface.co/distilbert-base-cased/resolve/main/',
    remoteBaseOnnx: null,
    exportFrom: 'dslim/distilbert-NER',
  },
  {
    id: 'gagan3012/bert-tiny-finetuned-ner',
    core: [
      'config.json',
      'onnx/model_quantized.onnx',
    ],
    tokenizerAlt: [
      'tokenizer.json',
      'vocab.txt',
    ],
    extra: [
      'tokenizer_config.json',
    ],
    remoteBase: 'https://huggingface.co/gagan3012/bert-tiny-finetuned-ner/resolve/main/',
  },
  {
    id: 'mrm8488/mobilebert-finetuned-ner',
    core: [
      'config.json',
      // If you have only non-quantized, change below to onnx/model.onnx
      'onnx/model_quantized.onnx',
    ],
    tokenizerAlt: [
      // mobilebert often ships vocab.txt
      'tokenizer.json',
      'vocab.txt',
    ],
    extra: [
      'tokenizer_config.json',
    ],
    // Repo usually lacks ONNX; we'll still download config/tokenizer from HF and then convert
    remoteBase: 'https://huggingface.co/mrm8488/mobilebert-finetuned-ner/resolve/main/',
    remoteBaseOnnx: null,
    exportFrom: 'mrm8488/mobilebert-finetuned-ner',
  },
  {
    id: 'dslim/distilbert-NER',
    core: [
      'config.json',
      'onnx/model_quantized.onnx',
    ],
    tokenizerAlt: [
      'tokenizer.json',
      'vocab.txt',
    ],
    extra: [
      'tokenizer_config.json',
    ],
    remoteBase: 'https://huggingface.co/dslim/distilbert-NER/resolve/main/',
  },
  {
    id: 'Mozilla/mobilebert-uncased-finetuned-LoRA-intent-classifier',
    core: [
      'config.json',
      'onnx/model_quantized.onnx',
    ],
    tokenizerAlt: [
      'tokenizer.json',
      'vocab.txt',
    ],
    extra: [
      'tokenizer_config.json',
    ],
    remoteBase: 'https://huggingface.co/Mozilla/mobilebert-uncased-finetuned-LoRA-intent-classifier/resolve/main/',
    remoteBaseOnnx: null,
    exportFrom: 'Mozilla/mobilebert-uncased-finetuned-LoRA-intent-classifier',
    task: 'sequence-classification',
  },
  {
    id: 'boltuix/NeuroBERT-Mini',
    core: [
      'config.json',
      'onnx/model_quantized.onnx',
    ],
    tokenizerAlt: [
      'tokenizer.json',
      'vocab.txt',
    ],
    extra: [
      'tokenizer_config.json',
    ],
    remoteBase: 'https://huggingface.co/boltuix/NeuroBERT-Mini/resolve/main/',
    remoteBaseOnnx: null,
    exportFrom: 'boltuix/NeuroBERT-Mini',
    task: 'sequence-classification',
  },
  {
    id: 'dmis-lab/TinyPubMedBERT-v1.0',
    core: [
      'config.json',
      'onnx/model_quantized.onnx',
    ],
    tokenizerAlt: [
      'tokenizer.json',
      'vocab.txt',
    ],
    extra: [
      'tokenizer_config.json',
    ],
    remoteBase: 'https://huggingface.co/dmis-lab/TinyPubMedBERT-v1.0/resolve/main/',
    remoteBaseOnnx: null,
    exportFrom: 'dmis-lab/TinyPubMedBERT-v1.0',
    task: 'token-classification',
  },
  {
    id: 'mrm8488/TinyBERT-spanish-uncased-finetuned-ner',
    core: [
      'config.json',
      'onnx/model_quantized.onnx',
    ],
    tokenizerAlt: [
      'tokenizer.json',
      'vocab.txt',
    ],
    extra: [
      'tokenizer_config.json',
    ],
    remoteBase: 'https://huggingface.co/mrm8488/TinyBERT-spanish-uncased-finetuned-ner/resolve/main/',
    remoteBaseOnnx: null,
    exportFrom: 'mrm8488/TinyBERT-spanish-uncased-finetuned-ner',
    task: 'token-classification',
  },
  {
    id: 'boltuix/NeuroBERT-Small',
    core: [
      'config.json',
      'onnx/model_quantized.onnx',
    ],
    tokenizerAlt: [
      'tokenizer.json',
      'vocab.txt',
    ],
    extra: [
      'tokenizer_config.json',
    ],
    remoteBase: 'https://huggingface.co/boltuix/NeuroBERT-Small/resolve/main/',
    remoteBaseOnnx: null,
    exportFrom: 'boltuix/NeuroBERT-Small',
    task: 'sequence-classification',
  },
]

async function ensureDir(p) {
  await fsp.mkdir(p, { recursive: true })
}

function fetchToFile(url, dest, depth = 0) {
  const MAX_REDIRECTS = 10
  return new Promise((resolve, reject) => {
    const doRequest = (currentUrl, n) => {
      const out = fs.createWriteStream(dest)
      const headers = { 'User-Agent': 'oneaifw-prep/1.0', 'Accept': '*/*' }
      if (HF_TOKEN) headers['Authorization'] = `Bearer ${HF_TOKEN}`
      const options = { agent: HTTPS_AGENT, headers }
      https.get(currentUrl, options, (res) => {
        const status = res.statusCode || 0
        if ([301, 302, 303, 307, 308].includes(status) && res.headers && res.headers.location) {
          out.close()
          fsp.rm(dest).catch(() => {})
          if (n >= MAX_REDIRECTS) {
            return reject(new Error(`Too many redirects for ${currentUrl}`))
          }
          const nextUrl = new URL(res.headers.location, currentUrl).toString()
          return doRequest(nextUrl, n + 1)
        }
        if (status !== 200) {
          out.close()
          fsp.rm(dest).catch(() => {})
          return reject(new Error(`HTTP ${status} for ${currentUrl}`))
        }
        res.pipe(out)
        out.on('finish', () => out.close(resolve))
      }).on('error', (err) => {
        out.close()
        fsp.rm(dest).catch(() => {})
        reject(err)
      })
    }
    doRequest(url, depth)
  })
}

function buildRemoteUrl(relPath, remoteBase) {
  let base = remoteBase
  if (HF_ENDPOINT && typeof base === 'string' && base.startsWith('https://huggingface.co/')) {
    const endpoint = HF_ENDPOINT.endsWith('/') ? HF_ENDPOINT : `${HF_ENDPOINT}/`
    base = base.replace('https://huggingface.co/', endpoint)
  }
  return new URL(relPath, base).toString()
}

async function ensureFile(baseDir, relPath, remoteBase) {
  const dest = path.join(baseDir, relPath)
  await ensureDir(path.dirname(dest))
  try {
    await fsp.access(dest)
    return true
  } catch (_) {}
  if (!OFFLINE && remoteBase) {
    const url = buildRemoteUrl(relPath, remoteBase)
    try {
      await fetchToFile(url, dest)
      console.log(`[prep-models] downloaded: ${relPath}`)
      return true
    } catch (e) {
      console.warn(`[prep-models] download failed: ${relPath}: ${e.message} (check network/proxy; if blocked, place file manually)`) 
    }
  }
  return false
}

async function ensureOneOf(baseDir, alternatives, remoteBase) {
  for (const rel of alternatives) {
    const ok = await ensureFile(baseDir, rel, remoteBase)
    if (ok) return rel
  }
  return null
}

async function prepareModel(model) {
  const { id, core, tokenizerAlt, extra } = model
  const base = path.join(MODELS_DIR, id)
  await ensureDir(base)

  // Ensure tokenizer: try tokenizer.json, then vocab.txt
  const tokenBase = model.remoteBaseToken || model.remoteBase
  const tok = await ensureOneOf(base, tokenizerAlt, tokenBase)
  if (!tok) {
    const msg = `[prep-models] tokenizer missing for ${id}. Tried: ${tokenizerAlt.join(', ')} (offline=${OFFLINE})`
    if (STRICT) throw new Error(msg)
    console.warn(msg)
  } else {
    console.log(`[prep-models] tokenizer ready for ${id}: ${tok}`)
  }

  // Ensure extra helper files
  for (const rel of extra) {
    const cfgBase = model.remoteBaseConfig || model.remoteBase
    const ok = await ensureFile(base, rel, cfgBase)
    if (!ok) {
      const msg = `[prep-models] extra file missing for ${id}: ${rel} (offline=${OFFLINE})`
      if (STRICT) throw new Error(msg)
      console.warn(msg)
    }
  }

  // Ensure core model files (prefer quantized if listed)
  for (const rel of core) {
    const onnxBase = rel.startsWith('onnx/') ? (model.remoteBaseOnnx || model.remoteBase) : (model.remoteBaseConfig || model.remoteBase)
    const ok = await ensureFile(base, rel, onnxBase)
    if (!ok) {
      const msg = `[prep-models] core file missing for ${id}: ${rel} (offline=${OFFLINE})`
      if (STRICT) throw new Error(msg)
      console.warn(msg)
    }
  }

  // Trigger quantization/export if needed right after preparation for this model
  console.log(`[prep-models] post-prepare check for quantized ONNX: ${id}`)
  await ensureQuantizedIfMissing(model)
}

function resolvePythonBin() {
  if (process.env.PYTHON) return process.env.PYTHON
  if (process.env.VIRTUAL_ENV) {
    const cand = path.join(process.env.VIRTUAL_ENV, 'bin', 'python')
    return cand
  }
  return 'python3'
}

function runPythonQuantizer(sourceRepo, targetId) {
  return new Promise((resolve) => {
    const py = resolvePythonBin()
    const tool = path.join(TOOLS_DIR, 'to-onnx-quanted.py')
    const args = [tool, '--model', sourceRepo, '--out-dir', MODELS_DIR, '--name', targetId]
    console.log(`[prep-models] converting to quantized ONNX via Python: src=${sourceRepo} -> dst=${targetId}`)
    console.log(`[prep-models] using python: ${py}`)
    const child = spawn(py, args, { stdio: 'inherit', env: process.env })
    child.on('error', (e) => {
      console.warn(`[prep-models] python failed to start: ${e.message}`)
      resolve(false)
    })
    child.on('close', (code, signal) => {
      if (code === 0) return resolve(true)
      console.warn(`[prep-models] python converter exited with code ${code}, signal=${signal || 'none'}`)
      resolve(false)
    })
  })
}

async function ensureQuantizedIfMissing(model) {
  const modelId = model.id
  const exportFrom = model.exportFrom || modelId
  const qPath = path.join(MODELS_DIR, modelId, 'onnx', 'model_quantized.onnx')
  try {
    const st = await fsp.stat(qPath)
    const onnxDir = path.dirname(qPath)
    const entries = await fsp.readdir(onnxDir).catch(() => [])
    const appearsInListing = Array.isArray(entries) && entries.includes('model_quantized.onnx')
    if (st.isFile() && st.size > 1024 && appearsInListing) {
      console.log(`[prep-models] quantized model found: ${qPath} (size=${st.size})`)
      return true
    }
    console.warn(`[prep-models] quantized file check mismatch (isFile=${st.isFile()}, size=${st.size}, inDir=${appearsInListing}); will regenerate: ${qPath}`)
  } catch (_) {}
  console.log(`[prep-models] quantized model missing, attempting conversion: ${modelId}`)
  // Pass task to exporter via env
  const prevTask = process.env.EXPORT_TASK
  if (model.task) process.env.EXPORT_TASK = model.task
  const ok = await runPythonQuantizer(exportFrom, modelId)
  if (prevTask === undefined) delete process.env.EXPORT_TASK; else process.env.EXPORT_TASK = prevTask
  if (ok) {
    try {
      const st2 = await fsp.stat(qPath)
      const entries2 = await fsp.readdir(path.dirname(qPath)).catch(() => [])
      if (st2.isFile() && st2.size > 1024 && Array.isArray(entries2) && entries2.includes('model_quantized.onnx')) {
        console.log(`[prep-models] quantized model ready for ${modelId} (size=${st2.size})`)
        return true
      }
    } catch (_) {}
  }
  console.warn(`[prep-models] quantized model still missing for ${modelId}. Ensure Python deps (torch, transformers, onnxruntime) and network access.`)
  return false
}

async function main() {
  await ensureDir(MODELS_DIR)
  // Ensure ONNX Runtime WASM assets are available under public/wasm
  try {
    await ensureDir(WASM_PUBLIC_DIR)
    const wasmFiles = [
      'ort-wasm.wasm',
      'ort-wasm-simd.wasm',
      'ort-wasm-threaded.wasm',
      // package filename is simd-threaded, serve as-is
      'ort-wasm-simd-threaded.wasm',
    ]
    for (const f of wasmFiles) {
      const src = path.join(WASM_NODE_DIR, f)
      const dst = path.join(WASM_PUBLIC_DIR, f)
      try {
        await fsp.copyFile(src, dst)
        // no log spam in normal runs
      } catch (e) {
        // best-effort; if missing, leave it to CDN or middleware
      }
    }
  } catch (_) {}
  console.log(`[prep-models] mode: offline=${OFFLINE} strict=${STRICT} allow_remote=${!OFFLINE}`)
  for (const m of SUPPORTED) {
    console.log(`[prep-models] preparing: ${m.id}`)
    await prepareModel(m)
  }
}

main().catch((e) => {
  console.error(`[prep-models] failed:`, e)
  process.exit(1)
})
