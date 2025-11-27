# OneAIFW Backend Service API

This document describes the HTTP API of the local OneAIFW backend service.

Default base URL: `http://127.0.0.1:8844`

Optional auth: request header `Authorization` (effective only if the server enables API_KEY), value can be `<key>` or `Bearer <key>`.

### General Notes
- Character encoding: UTF-8
- Error responses:
  - 401 Unauthorized: missing or invalid `Authorization`
  - 400 Bad Request: invalid request body

## Health Check
- Method/Path: GET `/api/health`
- Request body: none
- Response (JSON):
```json
{ "status": "ok" }
```

Example (curl):
```bash
curl -s -X GET http://127.0.0.1:8844/api/health
```
response:
```json
{ "status": "ok" }
```

## LLM Call (Anonymize → LLM → Restore)
- Method/Path: POST `/api/call`
- Content-Type: `application/json`
- Headers: `Authorization: <your-key>` (when the server requires auth)
- Request fields:
  - `text` (string, required): input text
  - `apiKeyFile` (string, optional): path to the LLM API config file read by the backend; if omitted, environment variable `AIFW_API_KEY_FILE` is used
  - `model` (string, optional): custom LLM model name (passed through to the backend LLM client)
  - `temperature` (number, optional): sampling temperature, default 0.0
- Response (JSON):
```json
{ "output":{"text": "<final_restored_text>"}, "error": null }
```

Example (curl):
```bash
curl -s -X POST http://127.0.0.1:8844/api/call \
  -H 'Content-Type: application/json' \
  # -H 'Authorization: Bearer <your-key>' \
  -d '{"text":"请把如下文本翻译为中文: My email address is test@example.com, and my phone number is 18744325579."}'
```
response:
```json
{"output":{"text":"我的电子邮件地址是 test@example.com，我的电话号码是 18744325579。"},"error":null}
```

## Mask Configuration (runtime)

- Method/Path: POST `/api/config`
- Content-Type: `application/json`
- Headers: `Authorization: <your-key>` (when the server requires auth)
- Purpose: update the in-memory mask configuration of the running service without restarting it.
- Request body:
  - `maskConfig` (object, required): per-entity mask switches. Supported keys:
    - `maskAddress` (bool): physical address, default is false
    - `maskEmail` (bool): email address, default is true
    - `maskOrganization` (bool): organization / company name, default is true
    - `maskUserName` (bool): personal name / username, default is true
    - `maskPhoneNumber` (bool): phone number, default is true
    - `maskBankNumber` (bool): bank account number, default is true
    - `maskPayment` (bool): payment-related identifiers, default is true
    - `maskVerificationCode` (bool): verification / one-time codes, default is true
    - `maskPassword` (bool): passwords, default is true
    - `maskRandomSeed` (bool): random seeds / initialization values, default is true
    - `maskPrivateKey` (bool): private keys / secrets, default is true
    - `maskUrl` (bool): URLs, default is true
    - `maskAll` (bool): enable/disable all of the above, no default value
- Response (JSON):
```json
{ "output": { "status": "ok" }, "error": null }
```

Example (curl):
```bash
curl -s -X POST http://127.0.0.1:8844/api/config \
  -H 'Content-Type: application/json' \
  # -H 'Authorization: Bearer <your-key>' \
  -d '{
    "maskConfig": {
      "maskEmail": true,
      "maskPhoneNumber": true,
      "maskUserName": true,
      "maskAddress": false,
    }
  }'
```

## Mask and Restore

These two API interface are used together to mask a piece of text, process the masked text (e.g., translation), and then restore it. They must be used as a pair: every mask call requires a corresponding restore call, otherwise memory may leak. You can call the mask interface in batches, process all masked texts, and then call the restore interface in batches with the matching metadata.

Important: paired mask and restore calls must use the same `maskMeta`. `maskMeta` is a base64 string of the UTF-8 JSON bytes of `placeholdersMap`.

### Mask interface (produce masked text and maskMeta)
- Method/Path: POST `/api/mask_text`
- Request Content-Type: `application/json`
- Headers: `Authorization: <your-key>` (when the server requires auth)
- Request fields:
  - `text` (string, required): input text
  - `language` (string, optional): language hint (e.g., `en`, `zh`); if omitted, the server auto-detects
- Response Content-Type: `application/json`
- Response body:
```json
{
  "output":{
    "text": "<masked_text>",
    "maskMeta": "<base64(placeholdersMap_json_bytes)>"
  },
  "error": null
}
```

Example (curl):
```bash
curl -s -X POST http://127.0.0.1:8844/api/mask_text \
  -H 'Content-Type: application/json' \
  # -H 'Authorization: Bearer <your-key>' \
  -d '{"text":"My email address is test@example.com, and my phone number is 18744325579.","language":"en"}'
```
response:
```json
{
  "output":{
    "text":"My email address is __PII_EMAIL_ADDRESS_00000001__, and my phone number is __PII_PHONE_NUMBER_00000002__.",
    "maskMeta":"eyJfX1BJSV9QSE9ORV9OVU1CRVJfMDAwMDAwMDJfXyI6ICIxODc0NDMyNTU3OSIsICJfX1BJSV9FTUFJTF9BRERSRVNTXzAwMDAwMDAxX18iOiAidGVzdEBleGFtcGxlLmNvbSJ9"
  },
  "error": null
}
```

### Restore interface (consume masked text and maskMeta to produce restored text)
- Method/Path: POST `/api/restore_text`
- Request Content-Type: `application/json`
- Headers: `Authorization: <your-key>` (when the server requires auth)
- Request body:
```json
{
  "text": "<MASKED_TEXT_FROM_PREVIOUS_STEP>",
  "maskMeta": "<BASE64_PLACEHOLDERSMAP_JSON_BYTES_FROM_PREVIOUS_STEP>"
}
```
- Response Content-Type: `application/json`
- Response body (to be filled):
```json
{
  "output":{"text": "<restored_text>"},
  "error": null
}
```

Example (curl):
```bash
curl -s -X POST http://127.0.0.1:8844/api/restore_text \
  -H 'Content-Type: application/json' \
  # -H 'Authorization: Bearer <your-key>' \
  -d '{"text":"My email address is __PII_EMAIL_ADDRESS_00000001__, and my phone number is __PII_PHONE_NUMBER_00000002__.", "maskMeta":"eyJfX1BJSV9QSE9ORV9OVU1CRVJfMDAwMDAwMDJfXyI6ICIxODc0NDMyNTU3OSIsICJfX1BJSV9FTUFJTF9BRERSRVNTXzAwMDAwMDAxX18iOiAidGVzdEBleGFtcGxlLmNvbSJ9"}'
```
response:
```json
{
  "output":{"text":"My email address is test@example.com, and my phone number is 18744325579."},
  "error":null
}
```

### Python Example
```python
import requests

base = "http://127.0.0.1:8844"

# 1) Example of mask_text (JSON → JSON)
r = requests.post(f"{base}/api/mask_text", json={"text": "张三电话13812345678", "language": "zh"})
r.raise_for_status()
obj = r.json()
output = obj["output"]
masked_text = output["text"]
mask_meta_b64 = output["maskMeta"]
print("masked:", masked_text)

# 2) Example of restore_text (JSON → JSON)
r2 = requests.post(f"{base}/api/restore_text", json={"text": masked_text, "maskMeta": mask_meta_b64})
r2.raise_for_status()
print("restored:", r2.json()["output"]["text"])
```

### Node.js (fetch) Example
```js
// Requires Node 18+ or bring your own fetch polyfill
const base = 'http://127.0.0.1:8844';

// 1) Example of mask_text (JSON → JSON)
const jr = await fetch(`${base}/api/mask_text`, {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ text: 'My email is test@example.com' })
});
if (!jr.ok) throw new Error(`mask_text http ${jr.status}`);
const obj = await jr.json();
const maskedText = (obj.output || {}).text;
const maskMetaB64 = (obj.output || {}).maskMeta;
console.log('masked:', maskedText);

// 2) Example of restore_text (JSON → JSON)
const rr = await fetch(`${base}/api/restore_text`, {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ text: maskedText, maskMeta: maskMetaB64 })
});
if (!rr.ok) throw new Error(`restore_text http ${rr.status}`);
const restoredObj = await rr.json();
console.log('restored:', (restoredObj.output || {}).text);

## Batch interfaces

### mask_text_batch
- Method/Path: POST `/api/mask_text_batch`
- Request Content-Type: `application/json`
- Headers: `Authorization: <your-key>` (when the server requires auth)
- Request body: JSON array of objects `{ text, language? }`
- Response Content-Type: `application/json`
- Response body:
```json
{
  "output": [
    { "text": "<masked_text_1>", "maskMeta": "<base64_meta_1>" },
    { "text": "<masked_text_2>", "maskMeta": "<base64_meta_2>" }
  ],
  "error": null
}
```

Example (curl):
```bash
curl -s -X POST http://127.0.0.1:8844/api/mask_text_batch \
  -H 'Content-Type: application/json' \
  # -H 'Authorization: Bearer <your-key>' \
  -d '[{"text":"My email address is test@example.com"}, {"text":"and my phone number is 18744325579.","language":"en"}]'
```
response:
```json
{
  "output":[
    {"text":"My email address is __PII_EMAIL_ADDRESS_00000001__",
     "maskMeta":"eyJfX1BJSV9FTUFJTF9BRERSRVNTXzAwMDAwMDAxX18iOiAidGVzdEBleGFtcGxlLmNvbSJ9"},
    {"text":"and my phone number is __PII_PHONE_NUMBER_00000001__.",
     "maskMeta":"eyJfX1BJSV9QSE9ORV9OVU1CRVJfMDAwMDAwMDFfXyI6ICIxODc0NDMyNTU3OSJ9"}
  ],
  "error": null
}
```

### restore_text_batch
- Method/Path: POST `/api/restore_text_batch`
- Request Content-Type: `application/json`
- Headers: `Authorization: <your-key>` (when the server requires auth)
- Request body: JSON array of objects `{ text, maskMeta }` (maskMeta is base64 string)
- Response Content-Type: `application/json`
- Response body:
```json
{
  "output": [
    {"text":"<restored_text_1>"},
    {"text":"<restored_text_2>"}
  ],
  "error": null
}
```

Example (curl):
```bash
curl -s -X POST http://127.0.0.1:8844/api/restore_text_batch \
  -H 'Content-Type: application/json' \
  # -H 'Authorization: Bearer <your-key>' \
  -d '[{"text":"My email address is __PII_EMAIL_ADDRESS_00000001__","maskMeta":"eyJfX1BJSV9FTUFJTF9BRERSRVNTXzAwMDAwMDAxX18iOiAidGVzdEBleGFtcGxlLmNvbSJ9"},{"text":"and my phone number is __PII_PHONE_NUMBER_00000001__.","maskMeta":"eyJfX1BJSV9QSE9ORV9OVU1CRVJfMDAwMDAwMDFfXyI6ICIxODc0NDMyNTU3OSJ9"}]'
```
response:
```json
{
  "output":["My email address is test@example.com","and my phone number is 18744325579."],
  "error":null
}
```

## Notes
- On the server side, `maskMeta` is the UTF-8 JSON serialization of `placeholdersMap`. Clients do not need to understand its structure—just pass it back to `/api/restore_text` as-is.
- If auth is enabled, include `Authorization` header in requests (value can be `<key>` or `Bearer <key>`).

