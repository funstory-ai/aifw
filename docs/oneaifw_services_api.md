# OneAIFW Backend Service API

This document describes the HTTP API and binary protocol of the local OneAIFW backend service.

Default base URL: `http://127.0.0.1:8844`

Optional auth: request header `X-API-Key` (effective only if the server enables API_KEY).

### General Notes
- Character encoding: UTF-8
- Error responses:
  - 401 Unauthorized: missing or invalid `X-API-Key`
  - 400 Bad Request: invalid/truncated binary payload

## Health Check
- Method/Path: GET `/api/health`
- Request body: none
- Response (JSON):
```json
{ "status": "ok" }
```

## LLM Call (Anonymize → LLM → Restore)
- Method/Path: POST `/api/call`
- Content-Type: `application/json`
- Request fields:
  - `text` (string, required): input text
  - `apiKeyFile` (string, optional): path to the LLM API config file read by the backend; if omitted, environment variable `AIFW_API_KEY_FILE` is used
  - `model` (string, optional): custom LLM model name (passed through to the backend LLM client)
  - `temperature` (number, optional): sampling temperature, default 0.0
- Response (JSON):
```json
{ "text": "<final_restored_text>" }
```

Example (curl):
```bash
curl -s -X POST http://127.0.0.1:8844/api/call \
  -H 'Content-Type: application/json' \
  -d '{"text":"My email is test@example.com","temperature":0.0}'
```

## Mask and Restore

These two API interface are used together to mask a piece of text, process the masked text (e.g., translation), and then restore it. They must be used as a pair: every mask call requires a corresponding restore call, otherwise memory may leak. You can call the mask interface in batches, process all masked texts, and then call the restore interface in batches with the matching metadata.

The binary frame format returned by the mask interface is identical to the binary frame format consumed by the restore interface (defined below). Important: paired mask and restore calls must use the same `maskMeta`.

### Binary Frame Format (little-endian)
1) 4 bytes unsigned integer N: the UTF-8 byte length of the following text
2) N bytes: UTF-8 text bytes (masked text in mask_text responses; masked text in restore_text requests)
3) Remaining bytes: raw `maskMeta` bytes (returned by mask_text; provided to restore_text)

Note: `maskMeta` is an opaque binary blob used internally by OneAIFW. Callers receive it as bytes from mask_text and should pass it back to restore_text without inspecting its content.

### Mask interface (produce masked text and maskMeta)
- Method/Path: POST `/api/mask_text`
- Request Content-Type: `application/json`
- Request fields:
  - `text` (string, required): input text
  - `language` (string, optional): language hint (e.g., `en`, `zh`); if omitted, the server auto-detects
- Response Content-Type: `application/octet-stream`
- Response body: a binary frame carrying masked text and raw `maskMeta` bytes

### Restore interface (consume masked text and maskMeta to produce restored text)
- Method/Path: POST `/api/restore_text`
- Request Content-Type: `application/octet-stream`
- Request body: a binary frame (see above) containing masked text and its matching raw `maskMeta` bytes
- Response Content-Type: `text/plain; charset=utf-8`
- Response body: restored plain text string

### Python Example
```python
import requests

base = "http://127.0.0.1:8844"

# 1) Call mask_text (JSON request → binary response)
r = requests.post(f"{base}/api/mask_text", json={"text": "张三电话13812345678", "language": "zh"})
r.raise_for_status()
blob = r.content

if len(blob) < 4:
    raise RuntimeError("invalid response")
text_len = int.from_bytes(blob[0:4], byteorder="little", signed=False)
masked_text = blob[4:4+text_len].decode("utf-8")
mask_meta_bytes = blob[4+text_len:]
print("masked:", masked_text)

# 2) Call restore_text (binary request → text response)
text_bytes = masked_text.encode("utf-8")
payload = len(text_bytes).to_bytes(4, "little") + text_bytes + mask_meta_bytes
r2 = requests.post(f"{base}/api/restore_text", data=payload, headers={"Content-Type": "application/octet-stream"})
r2.raise_for_status()
print("restored:", r2.text)
```

### Node.js (fetch) Example
```js
// Requires Node 18+ or bring your own fetch polyfill
const base = 'http://127.0.0.1:8844';

// 1) mask_text
const jr = await fetch(`${base}/api/mask_text`, {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ text: 'My email is test@example.com' })
});
if (!jr.ok) throw new Error(`mask_text http ${jr.status}`);
const buf = new Uint8Array(await jr.arrayBuffer());
const view = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
const textLen = view.getUint32(0, true);
const textBytes = buf.subarray(4, 4 + textLen);
const maskMetaBytes = buf.subarray(4 + textLen);
const maskedText = new TextDecoder().decode(textBytes);
console.log('masked:', maskedText);

// 2) restore_text
const mtBytes = new TextEncoder().encode(maskedText);
const header = new Uint8Array(4);
new DataView(header.buffer).setUint32(0, mtBytes.length, true);
const payload = new Uint8Array(4 + mtBytes.length + maskMetaBytes.length);
payload.set(header, 0);
payload.set(mtBytes, 4);
payload.set(maskMetaBytes, 4 + mtBytes.length);

const rr = await fetch(`${base}/api/restore_text`, {
  method: 'POST',
  headers: { 'Content-Type': 'application/octet-stream' },
  body: payload
});
if (!rr.ok) throw new Error(`restore_text http ${rr.status}`);
const restored = await rr.text();
console.log('restored:', restored);
```

## Notes
- On the server side, `maskMeta` is the UTF-8 JSON serialization of `placeholdersMap`. Clients do not need to understand its structure—just pass it back to `/api/restore_text` as-is.
- If auth is enabled, include `X-API-Key` in requests.

