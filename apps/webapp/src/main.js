const statusEl = document.getElementById('status');
const textEl = document.getElementById('text');
const maskedEl = document.getElementById('masked');
const restoredEl = document.getElementById('restored');
const runBtn = document.getElementById('run');
// Create language selector just above the textarea if not present
let langEl = document.getElementById('lang');
if (!langEl && textEl && textEl.parentElement) {
  const row = document.createElement('div');
  row.className = 'row';
  const label = document.createElement('label');
  label.htmlFor = 'lang';
  label.textContent = 'Language';
  const select = document.createElement('select');
  select.id = 'lang';
  // Supported: Simplified Chinese, Traditional Chinese, English
  const opts = [
    { v: 'zh', t: 'Chinese (Simplified)' },
    { v: 'zh-TW', t: 'Chinese (Traditional)' },
    { v: 'en', t: 'English' },
  ];
  for (const { v, t } of opts) {
    const o = document.createElement('option');
    o.value = v; o.textContent = t; select.appendChild(o);
  }
  // default to English
  select.value = 'en';
  row.appendChild(label);
  row.appendChild(select);
  // insert before the textarea row
  textEl.parentElement.parentElement?.insertBefore(row, textEl.parentElement);
  langEl = select;
}

// Create batch mode toggle above textarea
let batchEl = document.getElementById('use-batch');
if (!batchEl && textEl && textEl.parentElement) {
  const row = document.createElement('div');
  row.className = 'row';
  const label = document.createElement('label');
  const input = document.createElement('input');
  input.type = 'checkbox';
  input.id = 'use-batch';
  label.appendChild(input);
  label.appendChild(document.createTextNode(' Use batch (maskTextBatch)'));
  row.appendChild(label);
  textEl.parentElement.parentElement?.insertBefore(row, textEl.parentElement);
  batchEl = input;
}

let aifw; // wrapper lib

async function main() {
  statusEl.textContent = 'Initializing AIFW...';
  aifw = await import('@oneaifw/aifw-js');
  await aifw.init({ wasmBase: './wasm/' });
  statusEl.textContent = 'AIFW initialized.';

  // graceful shutdown on page exit (bfcache + unload)
  let shutdownCalled = false;
  function shutdownOnce() {
    if (shutdownCalled) return;
    shutdownCalled = true;
    aifw.deinit();
  }
  window.addEventListener('pagehide', shutdownOnce, { once: true });
  window.addEventListener('beforeunload', shutdownOnce, { once: true });

  runBtn.addEventListener('click', async () => {
    try {
      statusEl.textContent = 'Running...';
      maskedEl.textContent = '';
      restoredEl.textContent = '';

      const textStr = textEl.value || '';
      const language = (langEl && langEl.value) || 'en';
      const lines = textStr.split(/\r?\n/);
      const useBatch = !!(batchEl && batchEl.checked);
      let maskedLines = [];
      let metas = [];
      if (useBatch) {
        const inputs = lines.map((line) => ({ text: line, language }));
        const results = await aifw.maskTextBatch(inputs);
        maskedLines = results.map((r) => (r && r.text) || '');
        metas = results.map((r) => r && r.maskMeta);
      } else {
        for (const line of lines) {
          const [masked, meta] = await aifw.maskText(line, language);
          maskedLines.push(masked);
          metas.push(meta);
        }
      }
      const maskedStr = maskedLines.join('\n');
      maskedEl.textContent = maskedStr;

      const batchItems = maskedLines.map((m, i) => ({ text: m, maskMeta: metas[i] }));
      const restoredObjs = await aifw.restoreTextBatch(batchItems);
      const restoredStr = restoredObjs.map((o) => (o && o.text) || '').join('\n');
      restoredEl.textContent = restoredStr;

      // Test restore with empty masked text for just freeing meta, should return empty string
      try {
        const test_text = "Hi, my email is example.test@funstory.com, my phone number is 13800138027, my name is John Doe";
        const [masked, meta] = await aifw.maskText(test_text, language);
        const emptied = await aifw.restoreText('', meta);
        // Expect empty string; log for debug without affecting UI
        console.log('[webapp] empty-restore result length:', emptied.length);
      } catch (e) {
        console.warn('[webapp] empty-restore check failed:', e);
      }

      // Test getPiiSpans API on the original input
      try {
        const spans = await aifw.getPiiSpans(textStr, language);
        console.log('[webapp] getPiiSpans spans:', spans);
      } catch (e) {
        console.warn('[webapp] getPiiSpans failed:', e);
      }

      statusEl.textContent = 'Done';
    } catch (e) {
      statusEl.textContent = `Error: ${e.message || e}`;
    }
  });
}

main().catch((e) => statusEl.textContent = `Error: ${e.message || e}`);
