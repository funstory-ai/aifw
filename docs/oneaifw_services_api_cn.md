# OneAIFW 后台服务 API 文档

本文档描述了 OneAIFW 本地后台服务的 HTTP API。

默认服务地址：`http://127.0.0.1:8844`

可选鉴权：请求头 `X-API-Key`（仅当服务端启用了 API_KEY 时生效）。

### 通用说明
- 字符编码：UTF-8
- 错误返回：
  - 401 Unauthorized：缺少或错误的 `X-API-Key`
  - 400 Bad Request：非法请求内容

## 健康检查
- 方法/路径：GET `/api/health`
- 请求体：无
- 响应（JSON）：
```json
{ "status": "ok" }
```

示例（curl）：
```bash
curl -s -X GET http://127.0.0.1:8844/api/health
```
响应:
```json
{ "status": "ok" }
```

## LLM匿名化调用（匿名化 → LLM → 反匿名化）
- 方法/路径：POST `/api/call`
- Content-Type：`application/json`
- 请求体字段：
  - `text` (string, 必填)：原始输入文本
  - `apiKeyFile` (string, 可选)：后端读取的 LLM API 配置文件路径；若省略，使用环境变量 `AIFW_API_KEY_FILE`
  - `model` (string, 可选)：自己提供的LLM模型名（透传给后端 LLM 客户端）
  - `temperature` (number, 可选)：采样温度，默认 0.0
- 响应（JSON）：
```json
{ "text": "<final_restored_text>" }
```

示例（curl）：
```bash
curl -s -X POST http://127.0.0.1:8844/api/call \
  -H 'Content-Type: application/json' \
  -d '{"text":"请把如下文本翻译为中文: My email address is test@example.com, and my phone number is 18744325579."}'
```
响应:
```json
{"text":"我的电子邮件地址是 test@example.com，我的电话号码是 18744325579。"}
```

## 匿名化与反匿名化

这两个接口一起用于匿名化一段文本，处理匿名化的文本（比如翻译），再反匿名化处理后的文本。必须配对使用：每次匿名化都需要对应一次反匿名化，否则可能造成内存泄漏。可以先批量匿名化、处理完成后再批量反匿名化。

重要：配对的匿名化和反匿名化接口调用需要使用相同的 `maskMeta`。

`maskMeta` 是将 `placeholdersMap`（UTF-8 编码的 JSON 字节）整体 base64 编码得到的字符串；调用方将其视为不透明字符串，按原样传回 `/api/restore_text` 即可。

### 匿名化接口（生成 masked text 与 maskMeta）
- 方法/路径：POST `/api/mask_text`
- 请求 Content-Type：`application/json`
- 请求体字段：
  - `text` (string, 必填)：原始输入文本
  - `language` (string, 可选)：语言提示（如 `en`、`zh`）；若省略，服务端自动检测
- 响应 Content-Type：`application/json`
- 响应体：
```json
{
  "text": "<masked_text>",
  "maskMeta": "<base64(placeholdersMap_json_bytes)>"
}
```

示例（curl）：
```bash
curl -s -X POST http://127.0.0.1:8844/api/mask_text \
  -H 'Content-Type: application/json' \
  -d '{"text":"My email address is test@example.com, and my phone number is 18744325579.","language":"en"}'
```
响应:
```json
{
  "text":"My email address is __PII_EMAIL_ADDRESS_00000001__, and my phone number is __PII_PHONE_NUMBER_00000002__.",
  "maskMeta":"eyJfX1BJSV9QSE9ORV9OVU1CRVJfMDAwMDAwMDJfXyI6ICIxODc0NDMyNTU3OSIsICJfX1BJSV9FTUFJTF9BRERSRVNTXzAwMDAwMDAxX18iOiAidGVzdEBleGFtcGxlLmNvbSJ9"
}
```

### 反匿名化接口（输入 masked text 与 maskMeta 得到反匿名化后的文本）
- 方法/路径：POST `/api/restore_text`
- 请求 Content-Type：`application/json`
- 请求体：
```json
{
  "text": "<上一阶段返回的 masked_text>",
  "maskMeta": "<上一阶段返回的 base64(maskMeta)>"
}
```
- 响应 Content-Type：`application/json`
- 响应体：
```json
{
  "text": "<restored_text>"
}
```

示例（curl）：
```bash
curl -s -X POST http://127.0.0.1:8844/api/restore_text \
  -H 'Content-Type: application/json' \
  -d '{"text":"My email address is __PII_EMAIL_ADDRESS_00000001__, and my phone number is __PII_PHONE_NUMBER_00000002__.", "maskMeta":"eyJfX1BJSV9QSE9ORV9OVU1CRVJfMDAwMDAwMDJfXyI6ICIxODc0NDMyNTU3OSIsICJfX1BJSV9FTUFJTF9BRERSRVNTXzAwMDAwMDAxX18iOiAidGVzdEBleGFtcGxlLmNvbSJ9"}'
```
响应:
```json
{"text":"My email address is test@example.com, and my phone number is 18744325579."}
```

### Python 使用示例
```python
import requests

base = "http://127.0.0.1:8844"

# 1) 调用例子 mask_text（JSON → JSON）
r = requests.post(f"{base}/api/mask_text", json={"text": "张三电话13812345678", "language": "zh"})
r.raise_for_status()
obj = r.json()
masked_text = obj["text"]
mask_meta_b64 = obj["maskMeta"]
print("masked:", masked_text)

# 2) 调用例子 restore_text（JSON → JSON）
r2 = requests.post(f"{base}/api/restore_text", json={"text": masked_text, "maskMeta": mask_meta_b64})
r2.raise_for_status()
print("restored:", r2.json()["text"])
```

### Node.js（fetch）示例
```js
// 需要 Node 18+ 或自行引入 fetch polyfill
const base = 'http://127.0.0.1:8844';

// 1) 调用例子 mask_text（JSON → JSON）
const jr = await fetch(`${base}/api/mask_text`, {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ text: 'My email is test@example.com' })
});
if (!jr.ok) throw new Error(`mask_text http ${jr.status}`);
const obj = await jr.json();
const maskedText = obj.text;
const maskMetaB64 = obj.maskMeta;
console.log('masked:', maskedText);

// 2) 调用例子 restore_text（JSON → JSON）
const rr = await fetch(`${base}/api/restore_text`, {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ text: maskedText, maskMeta: maskMetaB64 })
});
if (!rr.ok) throw new Error(`restore_text http ${rr.status}`);
const restoredObj = await rr.json();
console.log('restored:', restoredObj.text);
```

## 批量接口

### 匿名化批量接口：mask_text_batch
- 方法/路径：POST `/api/mask_text_batch`
- 请求 Content-Type：`application/json`
- 请求体：对象数组，每项 `{ text, language? }`
- 响应 Content-Type：`application/json`
- 响应体（待填充实际内容）：
```json
{
  "resp_array": [
    { "text": "<masked_text_1>", "maskMeta": "<base64_meta_1>" },
    { "text": "<masked_text_2>", "maskMeta": "<base64_meta_2>" }
  ]
}
```

示例（curl）：
```bash
curl -s -X POST http://127.0.0.1:8844/api/mask_text_batch \
  -H 'Content-Type: application/json' \
  -d '[{"text":"My email address is test@example.com"}, {"text":"and my phone number is 18744325579.","language":"en"}]'
```
响应:
```json
{"resp_array":[
    {"text":"My email address is __PII_EMAIL_ADDRESS_00000001__",
     "maskMeta":"eyJfX1BJSV9FTUFJTF9BRERSRVNTXzAwMDAwMDAxX18iOiAidGVzdEBleGFtcGxlLmNvbSJ9"},
    {"text":"and my phone number is __PII_PHONE_NUMBER_00000001__.",
     "maskMeta":"eyJfX1BJSV9QSE9ORV9OVU1CRVJfMDAwMDAwMDFfXyI6ICIxODc0NDMyNTU3OSJ9"}
  ]
}
```

### 反匿名化批量接口：restore_text_batch
- 方法/路径：POST `/api/restore_text_batch`
- 请求 Content-Type：`application/json`
- 请求体：对象数组，每项 `{ text, maskMeta }`（`maskMeta` 为 base64 字符串）
- 响应 Content-Type：`application/json`
- 响应体（待填充实际内容）：
```json
{
  "restored_array": [
    "<restored_text_1>",
    "<restored_text_2>"
  ]
}
```

示例（curl）：
```bash
curl -s -X POST http://127.0.0.1:8844/api/restore_text_batch \
  -H 'Content-Type: application/json' \
  -d '[{"text":"My email address is __PII_EMAIL_ADDRESS_00000001__","maskMeta":"eyJfX1BJSV9FTUFJTF9BRERSRVNTXzAwMDAwMDAxX18iOiAidGVzdEBleGFtcGxlLmNvbSJ9"},{"text":"and my phone number is __PII_PHONE_NUMBER_00000001__.","maskMeta":"eyJfX1BJSV9QSE9ORV9OVU1CRVJfMDAwMDAwMDFfXyI6ICIxODc0NDMyNTU3OSJ9"}]'
```
响应:
```json
{"restored_array":["My email address is test@example.com","and my phone number is 18744325579."]}
```

## 附注
- `maskMeta` 的内容在服务端是 `placeholdersMap` 的 UTF-8 JSON 字节整体 base64 编码；客户端无需理解其结构，按原样传回 `restore_text` 即可。
- 若启用鉴权，请在请求头携带 `X-API-Key`。
