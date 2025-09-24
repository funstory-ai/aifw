#!/usr/bin/env node
import fs from 'node:fs'
import path from 'node:path'
import url from 'node:url'
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)

const __filename = url.fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)

function ensureDir(p) {
  fs.mkdirSync(p, { recursive: true })
}

function copyFile(src, destDir) {
  ensureDir(destDir)
  const dest = path.join(destDir, path.basename(src))
  fs.copyFileSync(src, dest)
  console.log('[copy]', src, '->', dest)
}

function copyDir(src, dest) {
  ensureDir(dest)
  for (const e of fs.readdirSync(src)) {
    const s = path.join(src, e)
    const d = path.join(dest, e)
    const st = fs.statSync(s)
    if (st.isDirectory()) copyDir(s, d)
    else copyFile(s, dest)
  }
}

function resolveTransformersOrtWasm() {
  let pkgPath
  try {
    pkgPath = path.dirname(require.resolve('@xenova/transformers/package.json'))
  } catch (e) {
    return null
  }
  const ortWasmFilePath = path.join(pkgPath, 'dist/ort-wasm-simd-threaded.wasm')
  if (!fs.existsSync(ortWasmFilePath)) return null
  return ortWasmFilePath
}

function copyTransformersWasm(outRoot) {
  const ortWasmFilePath = resolveTransformersOrtWasm()
  if (ortWasmFilePath) {
    copyFile(ortWasmFilePath, path.join(outRoot, 'wasm'))
    return true
  }
  console.error('[error] @xenova/transformers/ort-wasm-simd-threaded.wasm not found, aborting')
  return false
}

function copyCoreWasm(outRoot) {
  const core = path.resolve(__dirname, '../../..', 'zig-out', 'bin', 'liboneaifw_core.wasm')
  if (!fs.existsSync(core)) {
    console.warn('[warn] core wasm not found:', core)
    return
  }
  copyFile(core, path.join(outRoot, 'wasm'))
}

function copyModels(outRoot) {
  const modelsDir = process.env.AIFW_MODELS_DIR
    ? path.resolve(process.env.AIFW_MODELS_DIR)
    : path.resolve(__dirname, '../../..', 'ner-models')
  const modelIds = (process.env.AIFW_MODEL_IDS || 'Xenova/distilbert-base-cased-finetuned-conll03-english')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean)

  const files = [
    'tokenizer.json',
    'tokenizer_config.json',
    'config.json',
    'special_tokens_map.json',
    'vocab.txt',
  ]

  for (const id of modelIds) {
    const srcRoot = path.join(modelsDir, id)
    const outRootModel = path.join(outRoot, 'models', id)
    if (!fs.existsSync(srcRoot)) throw new Error('model dir missing: ' + srcRoot)
    // quantized onnx
    const q = path.join(srcRoot, 'onnx', 'model_quantized.onnx')
    if (!fs.existsSync(q)) throw new Error('quantized onnx missing: ' + q)
    copyFile(q, path.join(outRootModel, 'onnx'))
    // configs
    for (const f of files) {
      const p = path.join(srcRoot, f)
      if (!fs.existsSync(p)) {
        console.warn('[warn] model config missing:', p)
        continue
      }
      copyFile(p, outRootModel)
    }
  }
}

function main() {
  const outRoot = path.resolve(__dirname, '..', 'dist')
  ensureDir(outRoot)
  copyTransformersWasm(outRoot)
  copyCoreWasm(outRoot)
  copyModels(outRoot)
}

main()
