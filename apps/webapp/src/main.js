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
    { v: 'auto', t: 'Auto (detect)' },
    { v: 'zh-CN', t: 'Chinese (Simplified)' },
    { v: 'zh-TW', t: 'Chinese (Traditional)' },
    { v: 'en', t: 'English' },
  ];
  for (const { v, t } of opts) {
    const o = document.createElement('option');
    o.value = v; o.textContent = t; select.appendChild(o);
  }
  // default to Auto
  select.value = 'auto';
  row.appendChild(label);
  row.appendChild(select);
  // detected language indicator
  const detSpan = document.createElement('span');
  detSpan.id = 'lang-detected';
  detSpan.style.marginLeft = '8px';
  row.appendChild(detSpan);
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

// Create mask-config checkboxes above textarea (to the right of language/batch rows)
const maskCheckboxes = {};
if (textEl && textEl.parentElement) {
  const row = document.createElement('div');
  row.className = 'row';
  const title = document.createElement('span');
  title.textContent = 'Mask types:';
  row.appendChild(title);
  const defs = [
    { key: 'maskAddress', id: 'maskAddress', label: 'Address', checked: true },
    { key: 'maskEmail', id: 'maskEmail', label: 'Email', checked: true },
    { key: 'maskOrganization', id: 'maskOrganization', label: 'Organization', checked: true },
    { key: 'maskUserName', id: 'maskUserName', label: 'User name', checked: true },
    { key: 'maskPhoneNumber', id: 'maskPhoneNumber', label: 'Phone', checked: true },
    { key: 'maskBankNumber', id: 'maskBankNumber', label: 'Bank', checked: true },
    { key: 'maskPayment', id: 'maskPayment', label: 'Payment', checked: true },
    { key: 'maskVerificationCode', id: 'maskVerificationCode', label: 'Verification code', checked: true },
    { key: 'maskPassword', id: 'maskPassword', label: 'Password', checked: true },
    { key: 'maskRandomSeed', id: 'maskRandomSeed', label: 'Random seed', checked: true },
    { key: 'maskPrivateKey', id: 'maskPrivateKey', label: 'Private key', checked: true },
    { key: 'maskUrl', id: 'maskUrl', label: 'URL', checked: true },
  ];
  for (const def of defs) {
    const label = document.createElement('label');
    label.style.marginLeft = '12px';
    const input = document.createElement('input');
    input.type = 'checkbox';
    input.id = def.id;
    input.checked = def.checked;
    label.appendChild(input);
    label.appendChild(document.createTextNode(' ' + def.label));
    row.appendChild(label);
    maskCheckboxes[def.key] = input;
  }
  textEl.parentElement.parentElement?.insertBefore(row, textEl.parentElement);
}

function getMaskConfigFromUI() {
  const cfg = {};
  for (const [key, el] of Object.entries(maskCheckboxes)) {
    cfg[key] = !!el.checked;
  }
  return cfg;
}

let aifw; // wrapper lib

async function main() {
  statusEl.textContent = 'Initializing AIFW...';
  aifw = await import('@oneaifw/aifw-js');
  // await aifw.init({ wasmBase: './wasm/' });
  await aifw.init({ maskConfig: getMaskConfigFromUI() });
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

  // When user toggles mask checkboxes, update config at runtime
  for (const el of Object.values(maskCheckboxes)) {
    el.addEventListener('change', () => {
      if (!aifw || typeof aifw.config !== 'function') return;
      const cfg = getMaskConfigFromUI();
      aifw.config(cfg).catch((e) => console.warn('[webapp] config failed', e));
    });
  }

  runBtn.addEventListener('click', async () => {
    try {
      statusEl.textContent = 'Running...';
      maskedEl.textContent = '';
      restoredEl.textContent = '';

      const textStr = textEl.value || '';
      let language = (langEl && langEl.value) || 'auto';
      const lines = textStr.split(/\r?\n/);
      const useBatch = !!(batchEl && batchEl.checked);
      let maskedLines = [];
      let metas = [];
      // detect language if auto (for display only). Library will also auto-detect per text when language is null/auto
      let displayLang = '';
      if (language === 'auto') {
        try {
          const det = await aifw.detectLanguage(textStr);
          if (det.lang === 'zh') displayLang = det.script === 'Hant' ? 'zh-TW' : 'zh-CN'; else displayLang = det.lang || 'en';
        } catch (_) {}
        const span = document.getElementById('lang-detected');
        if (span) span.textContent = displayLang ? `(detected: ${displayLang})` : '';
        language = null; // pass null to trigger library auto-detect
      }
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
