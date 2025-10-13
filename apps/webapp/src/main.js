const statusEl = document.getElementById('status');
const textEl = document.getElementById('text');
const maskedEl = document.getElementById('masked');
const restoredEl = document.getElementById('restored');
const runBtn = document.getElementById('run');

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
      const lines = textStr.split(/\r?\n/);
      const maskedLines = [];
      const metas = [];
      for (const line of lines) {
        const [masked, meta] = await aifw.maskText(line);
        maskedLines.push(masked);
        metas.push(meta);
      }
      const maskedStr = maskedLines.join('\n');
      maskedEl.textContent = maskedStr;

      const restoredLines = [];
      for (let i = 0; i < maskedLines.length; i++) {
        const rest = await aifw.restoreText(maskedLines[i], metas[i]);
        restoredLines.push(rest);
      }
      const restoredStr = restoredLines.join('\n');
      restoredEl.textContent = restoredStr;

      // Test restore with empty masked text for just freeing meta, should return empty string
      try {
        const test_text = "Hi, my email is example.test@funstory.com, my phone number is 13800138027, my name is John Doe";
        const [masked, meta] = await aifw.maskText(test_text);
        const emptied = await aifw.restoreText('', meta);
        // Expect empty string; log for debug without affecting UI
        console.log('[webapp] empty-restore result length:', emptied.length);
      } catch (e) {
        console.warn('[webapp] empty-restore check failed:', e);
      }

      statusEl.textContent = 'Done';
    } catch (e) {
      statusEl.textContent = `Error: ${e.message || e}`;
    }
  });
}

main().catch((e) => statusEl.textContent = `Error: ${e.message || e}`);
