import { defineConfig } from 'vite'
import { viteStaticCopy } from 'vite-plugin-static-copy'
import path from 'node:path'
import fs from 'node:fs'

function buildModelTargets() {
  const modelsDir = process.env.AIFW_MODELS_DIR
    ? path.resolve(process.env.AIFW_MODELS_DIR)
    : path.resolve(__dirname, '../..', 'ner-models');
  const modelIds = (process.env.AIFW_MODEL_IDS || 'Xenova/distilbert-base-cased-finetuned-conll03-english')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);

  const files = [
    'tokenizer.json',
    'tokenizer_config.json',
    'config.json',
    'special_tokens_map.json',
    'vocab.txt',
  ];

  const targets = [];
  for (const id of modelIds) {
    const srcRoot = path.join(modelsDir, id);
    // copy quantized onnx only
    const quant = path.join(srcRoot, 'onnx', 'model_quantized.onnx');
    if (fs.existsSync(quant)) {
      targets.push({ src: quant, dest: path.posix.join('models', id, 'onnx') });
    }
    // copy configs if they exist
    for (const f of files) {
      const p = path.join(srcRoot, f);
      if (fs.existsSync(p)) {
        targets.push({ src: p, dest: path.posix.join('models', id) });
      }
    }
  }
  return targets;
}

function coreWasmTarget() {
  const core = path.resolve(__dirname, '../..', 'zig-out', 'bin', 'liboneaifw_core.wasm');
  if (fs.existsSync(core)) {
    return { src: core, dest: 'wasm' };
  }
  return null;
}

export default defineConfig({
  build: {
    lib: {
      entry: path.resolve(__dirname, 'libaifw.js'),
      name: 'libaifw-js',
      fileName: () => 'aifw-js.js',
      formats: ['es'],
    },
    outDir: 'dist',
    emptyOutDir: true,
    rollupOptions: {
      external: ['@xenova/transformers'],
    },
  },
  plugins: [
    viteStaticCopy({
      targets: [
        // copy transformers wasm assets into dist/wasm from this package's node_modules
        { src: path.resolve(__dirname, 'node_modules/@xenova/transformers/dist/ort-wasm-simd-threaded.wasm'), dest: 'wasm' },
        // copy core wasm if present
        ...(coreWasmTarget() ? [coreWasmTarget()] : []),
        // copy only requested quantized models and their configs
        ...buildModelTargets(),
      ],
    }),
  ],
})
