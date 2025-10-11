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
    let sess = null;
    try {
      statusEl.textContent = 'Running...';
      maskedEl.textContent = '';
      restoredEl.textContent = '';

      sess = await aifw.createSession();

      const textStr = textEl.value || '';
      const lines = textStr.split(/\r?\n/);
      const maskedLines = [];
      const metas = [];
      for (const line of lines) {
        const [m, meta] = await aifw.maskText(sess, line);
        maskedLines.push(m);
        metas.push(meta);
      }
      const maskedStr = maskedLines.join('\n');
      maskedEl.textContent = maskedStr;

      const restoredLines = [];
      for (let i = 0; i < maskedLines.length; i++) {
        const rest = await aifw.restoreText(sess, maskedLines[i], metas[i]);
        restoredLines.push(rest);
      }
      const restoredStr = restoredLines.join('\n');
      restoredEl.textContent = restoredStr;

      statusEl.textContent = 'Done';
    } catch (e) {
      statusEl.textContent = `Error: ${e.message || e}`;
    } finally {
      if (sess) await aifw.destroySession(sess);
    }
  });
}

main().catch((e) => statusEl.textContent = `Error: ${e.message || e}`);
