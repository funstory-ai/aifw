// The IndexedDB for store model files that used by aifw-js
const DB_NAME = 'aifw-models';
const DB_VERSION = 1;
const STORE = 'files';

function openDB() {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, DB_VERSION);
    req.onupgradeneeded = () => {
      const db = req.result;
      if (!db.objectStoreNames.contains(STORE)) {
        const store = db.createObjectStore(STORE, { keyPath: 'url' });
        store.createIndex('url', 'url', { unique: true });
      }
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
    req.onblocked = () => console.warn('[idb] open blocked');
  });
}

function txDone(tx) {
  return new Promise((resolve, reject) => {
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
    tx.onabort = () => reject(tx.error || new Error('transaction aborted'));
  });
}

// Get model file from cache that stored in IndexedDB
export async function getFromCache(url) {
  const db = await openDB();
  const tx = db.transaction(STORE, 'readonly');
  const store = tx.objectStore(STORE);
  const rec = await new Promise((resolve, reject) => {
    const req = store.get(url);
    req.onsuccess = () => resolve(req.result || null);
    req.onerror = () => reject(req.error);
  });
  await txDone(tx);
  if (!rec) return null;

  // Support two storage format such as Blob or ArrayBuffer 
  if (rec.blob instanceof Blob) {
    const buf = await rec.blob.arrayBuffer();
    return new Uint8Array(buf);
  }
  if (rec.arrayBuffer) {
    return new Uint8Array(rec.arrayBuffer);
  }
  return null;
}

// Put the model file to indexedDB, the data can be format of
// ArrayBuffer/Uint8Array/Blob/Response
export async function putToCache(url, data, contentType) {
  let blob;
  if (data instanceof Response) {
    const type = data.headers.get('Content-Type') || contentType || 'application/octet-stream';
    const buf = await data.arrayBuffer();
    blob = new Blob([buf], { type });
  } else if (data instanceof Blob) {
    blob = data;
  } else {
    const type = contentType || 'application/octet-stream';
    const bytes = data instanceof Uint8Array ? data : new Uint8Array(data);
    blob = new Blob([bytes], { type });
  }

  const db = await openDB();
  const tx = db.transaction(STORE, 'readwrite');
  const store = tx.objectStore(STORE);
  await new Promise((resolve, reject) => {
    const req = store.put({ url, type: blob.type, blob });
    req.onsuccess = () => resolve();
    req.onerror = () => reject(req.error);
  });
  await txDone(tx);
}

// Delet the model file in IndexedDB
export async function deleteFromCache(url) {
  const db = await openDB();
  const tx = db.transaction(STORE, 'readwrite');
  const store = tx.objectStore(STORE);
  await new Promise((resolve, reject) => {
    const req = store.delete(url);
    req.onsuccess = () => resolve();
    req.onerror = () => reject(req.error);
  });
  await txDone(tx);
}

export async function clearCache() {
  const db = await openDB();
  const tx = db.transaction(STORE, 'readwrite');
  const store = tx.objectStore(STORE);
  await new Promise((resolve, reject) => {
    const req = store.clear();
    req.onsuccess = () => resolve();
    req.onerror = () => reject(req.error);
  });
  await txDone(tx);
}
