chrome.runtime.onInstalled.addListener(()=>{chrome.storage.sync.set({serviceUrl:'http://127.0.0.1:8000'})});
async function callService(path, body){ const s = await chrome.storage.sync.get(['serviceUrl']); const url = s.serviceUrl || 'http://127.0.0.1:8000'; const r = await fetch(url+path, {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify(body)}); return await r.json(); }

chrome.runtime.onMessage.addListener((msg, sender, sendResponse)=>{
  if(msg.type==='ANON'){ callService('/api/anonymize', {text:msg.text}).then(d=>sendResponse({ok:true,data:d})).catch(e=>sendResponse({ok:false,error:e.message})); return true; }
});
