// offscreen.js (runs in a DOM context, module allowed)
import * as aifw from './vendor/aifw-js/aifw-js.js'
import { modelsBase, ensureModelCached, initAifwWithCache, defaultModelId } from './aifw-extension-sample.js'

let ready = false

// try {
//   if (navigator.hardwareConcurrency && navigator.hardwareConcurrency > 1) {
//     Object.defineProperty(navigator, 'hardwareConcurrency', { value: 1, configurable: true });
//   }
// } catch {}

async function ensureReady() {
  if (ready) return
  await ensureModelCached(defaultModelId)
  await initAifwWithCache({})
  ready = true
}

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (msg && msg._aifw) {
    if (msg.cmd === 'ping') { sendResponse({ ok: true }); return; }
    (async () => {
      try {
        await ensureReady()
        if (msg.cmd === 'mask') {
          const sess = await aifw.createSession()
          try {
            const out = await aifw.maskText(sess, msg.text || '')
            sendResponse({ ok: true, text: out })
          } finally {
            await aifw.destroySession(sess)
          }
        } else if (msg.cmd === 'restore') {
          const sess = await aifw.createSession()
          try {
            const out = await aifw.restoreText(sess, msg.text || '')
            sendResponse({ ok: true, text: out })
          } finally {
            await aifw.destroySession(sess)
          }
        } else {
          sendResponse({ ok: false, error: 'unknown cmd' })
        }
      } catch (e) {
        sendResponse({ ok: false, error: e?.message || String(e) })
      }
    })()
    return true
  }
})
