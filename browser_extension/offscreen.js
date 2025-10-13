// offscreen.js (runs in a DOM context, module allowed)
import * as aifw from './vendor/aifw-js/aifw-js.js'
import { ensureModelCached, initAifwWithCache, defaultModelId } from './aifw-extension-sample.js'

let ready = false
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
          const text = msg.text || ''
          const lines = text.split(/\r?\n/)
          const maskedLines = []
          const metas = []
          for (const line of lines) {
            const [masked, meta] = await aifw.maskText(line)
            maskedLines.push(masked)
            metas.push(meta)
          }
          lastMetas = metas
          sendResponse({ ok: true, text: maskedLines.join('\n'), meta: metas })
        } else if (msg.cmd === 'restore') {
          const text = msg.text || ''
          const metas = Array.isArray(msg.meta) ? msg.meta : (lastMetas || [])
          const lines = text.split(/\r?\n/)
          const restoredLines = []
          for (let i=0;i<lines.length;i++) {
            const restored = await aifw.restoreText(lines[i], metas[i])
            restoredLines.push(restored)
          }
          lastMetas = null
          sendResponse({ ok: true, text: restoredLines.join('\n') })
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

// Ensure Zig core shutdown when offscreen document is closed
function shutdownOnce(){
  if (!ready) return
  try { aifw.deinit() } catch {}
  ready = false
  lastMetas = null
}

window.addEventListener('pagehide', shutdownOnce, { once: true })
window.addEventListener('beforeunload', shutdownOnce, { once: true })
