const statusEl = document.getElementById('status');
const textEl = document.getElementById('text');
const maskedEl = document.getElementById('masked');
const restoredEl = document.getElementById('restored');
const runBtn = document.getElementById('run');

let aifw; // wrapper lib

async function main() {
  statusEl.textContent = 'Initializing AIFW...';
  aifw = await import('/@fs/Users/liuchangsheng/Work/funstory-ai/OneAIFW/libs/aifw-js/libaifw.js');
  await aifw.init({ wasmBase: '/wasm/' });
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
      const maskedStr = await aifw.maskText(sess, textStr);
      maskedEl.textContent = maskedStr;

      const restoredStr = await aifw.restoreText(sess, maskedStr);
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
