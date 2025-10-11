// offscreen.js (runs in a DOM context, module allowed)
import * as aifw from './vendor/aifw-js/aifw-js.js'
import { ensureModelCached, initAifwWithCache, defaultModelId } from './aifw-extension-sample.js'

let ready = false
let sess = null
let lastMetas = null

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
          const text = msg.text || ''
          const lines = text.split(/\r?\n/)
          const masked = []
          const metas = []
          for (const line of lines) {
            const [m, meta] = await aifw.maskText(sess, line)
            masked.push(m)
            metas.push(meta)
          }
          lastMetas = metas
          sendResponse({ ok: true, text: masked.join('\n'), meta: metas })
        } else if (msg.cmd === 'restore') {
          if (!sess) { sendResponse({ ok: false, error: 'No active session. Run Mask first.' }); return; }
          const text = msg.text || ''
          const metas = Array.isArray(msg.meta) ? msg.meta : (lastMetas || [])
          const lines = text.split(/\r?\n/)
          const restored = []
          for (let i=0;i<lines.length;i++) {
            const rest = await aifw.restoreText(sess, lines[i], metas[i])
            restored.push(rest)
          }
          lastMetas = null
          sendResponse({ ok: true, text: restored.join('\n') })
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
