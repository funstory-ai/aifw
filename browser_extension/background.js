async function delay(ms){return new Promise(r=>setTimeout(r,ms))}
async function pingOffscreenOnce(timeoutMs=200){
  return new Promise((resolve)=>{
    let done=false
    const t=setTimeout(()=>{ if(!done) resolve(false) }, timeoutMs)
    try {
      chrome.runtime.sendMessage({ _aifw: true, cmd: 'ping' }, (resp)=>{
        // Read lastError to consume and avoid "Unchecked runtime.lastError" logs
        void chrome.runtime.lastError
        clearTimeout(t)
        done=true
        resolve(!!(resp && resp.ok))
      })
    } catch {
      clearTimeout(t)
      resolve(false)
    }
  })
}

async function ensureOffscreen() {
  // if already alive, return
  if (await pingOffscreenOnce(200)) return
  // create and wait until ready
  await chrome.offscreen.createDocument({
    url: 'offscreen.html',
    reasons: ['BLOBS'],
    justification: 'Run WASM and heavy JS for aifw in DOM context',
  })
  for (let i=0;i<15;i++){ // ~3s max
    if (await pingOffscreenOnce(200)) return
    await delay(200)
  }
  throw new Error('offscreen not ready')
}

async function offscreenCall(cmd, text) {
  await ensureOffscreen()
  return new Promise((resolve) => {
    chrome.runtime.sendMessage({ _aifw: true, cmd, text }, (resp) => resolve(resp))
  })
}

chrome.runtime.onInstalled.addListener(async () => {
  try {
    await ensureOffscreen()
    chrome.contextMenus.create({ id: 'aifw-mask', title: 'Anonymize with OneAIFW', contexts: ['selection'] })
  } catch (e) {
    console.error('[aifw-ext] init failed', e)
  }
})

chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  const type = info.menuItemId
  if (type !== 'aifw-mask') return
  if (!tab?.id) return
  try {
    const [{ result: sel }] = await chrome.scripting.executeScript({
      target: { tabId: tab.id },
      func: () => window.getSelection()?.toString() || ''
    })
    if (!sel) return
    const resp = await offscreenCall('mask', sel)
    if (resp?.ok) {
      await chrome.scripting.executeScript({ target: { tabId: tab.id }, func: (t) => navigator.clipboard.writeText(t), args: [resp.text] })
    } else {
      console.error('[aifw-ext] offscreen error', resp?.error)
    }
  } catch (e) {
    console.error('[aifw-ext] action failed', e)
  }
})

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (msg.type === 'ANON') {
    (async () => {
      const resp = await offscreenCall('mask', msg.text || '')
      if (resp?.ok) sendResponse({ ok: true, data: { text: resp.text } })
      else sendResponse({ ok: false, error: resp?.error || 'unknown' })
    })()
    return true
  }
  if (msg.type === 'RESTORE') {
    (async () => {
      const resp = await offscreenCall('restore', msg.text || '')
      if (resp?.ok) sendResponse({ ok: true, data: { text: resp.text } })
      else sendResponse({ ok: false, error: resp?.error || 'unknown' })
    })()
    return true
  }
})
