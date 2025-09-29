// popup.js
const input = document.getElementById('input')
const btnMask = document.getElementById('btn-mask')
const btnRestore = document.getElementById('btn-restore')
const statusEl = document.getElementById('status')
const maskedEl = document.getElementById('masked')
const restoredEl = document.getElementById('restored')

function setStatus(s) { statusEl.textContent = s || '' }

async function callBg(type, text) {
  return new Promise((resolve) => {
    chrome.runtime.sendMessage({ type, text }, (resp) => resolve(resp))
  })
}

btnMask.addEventListener('click', async () => {
  setStatus('Masking...')
  maskedEl.textContent = ''
  restoredEl.textContent = ''
  const resp = await callBg('ANON', input.value || '')
  if (resp?.ok) {
    maskedEl.textContent = resp.data.text
    setStatus('Done')
  } else {
    setStatus('Error: ' + (resp?.error || 'unknown'))
  }
})

btnRestore.addEventListener('click', async () => {
  setStatus('Restoring...')
  restoredEl.textContent = ''
  const resp = await callBg('RESTORE', input.value || '')
  if (resp?.ok) {
    restoredEl.textContent = resp.data.text
    setStatus('Done')
  } else {
    setStatus('Error: ' + (resp?.error || 'unknown'))
  }
})
