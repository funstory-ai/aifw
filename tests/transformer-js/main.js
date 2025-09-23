import { initEnv, buildNerPipeline } from '/@fs/Users/liuchangsheng/Work/funstory-ai/OneAIFW/libs/aifw-js/libner.js';

// Configure environment
initEnv({ wasmBase: '/wasm/' });

const runBtn = document.getElementById('run');
const textEl = document.getElementById('text');
const modelEl = document.getElementById('model');
const quantizedEl = document.getElementById('quantized');
const outEl = document.getElementById('out');

runBtn.addEventListener('click', async () => {
  try {
    const modelId = modelEl.value;
    const quantized = !!quantizedEl.checked;
    const text = textEl.value || '';

    const ner = await buildNerPipeline(modelId, { quantized });
    const t0 = performance.now();
    const output = await ner.run(text);
    const timeMs = Math.round(performance.now() - t0);

    outEl.textContent = JSON.stringify({ time_ms: timeMs, model: modelId, quantized, output }, null, 2);
  } catch (e) {
    outEl.textContent = `Error: ${e?.message || e}`;
  }
});

// Auto-run once on load
runBtn.click();

