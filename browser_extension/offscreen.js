// offscreen.js (runs in a DOM context, module allowed)
import * as aifw from './vendor/aifw-js/aifw-js.js'
import { ensureModelCached, initAifwWithCache, defaultModelId } from './aifw-extension-sample.js'

let ready = false
let sess = null

async function ensureReady() {
  if (ready) return
  await ensureModelCached(defaultModelId)
  await initAifwWithCache()
  ready = true
}

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (msg && msg._aifw) {
    if (msg.cmd === 'ping') { sendResponse({ ok: true }); return; }
    (async () => {
      try {
        await ensureReady()
        if (msg.cmd === 'mask') {
          if (!sess) sess = await aifw.createSession()
          const out = await aifw.maskText(sess, msg.text || '')
          sendResponse({ ok: true, text: out })
        } else if (msg.cmd === 'restore') {
          if (!sess) { sendResponse({ ok: false, error: 'No active session. Run Mask first.' }); return; }
          const out = await aifw.restoreText(sess, msg.text || '')
          sendResponse({ ok: true, text: out })
          await aifw.destroySession(sess)
          sess = null
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
