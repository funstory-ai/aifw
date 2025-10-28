## OneAIFW 后台服务 API 文档

本文档描述了 OneAIFW 本地后台服务的 HTTP API 及二进制协议。

默认服务地址：`http://127.0.0.1:8844`

可选鉴权：请求头 `X-API-Key`（仅当服务端启用了 API_KEY 时生效）。

### 通用说明
- 字符编码：UTF-8
- 错误返回：
  - 401 Unauthorized：缺少或错误的 `X-API-Key`
  - 400 Bad Request：非法/截断的二进制载荷

## 健康检查
- 方法/路径：GET `/api/health`
- 请求体：无
- 响应（JSON）：
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
  -d '{"text":"My email is test@example.com","temperature":0.0}'
```

## 匿名化与反匿名化

这两个接口一起用于匿名化一段文本，处理匿名化的文本（比如翻译），反匿名化处理后的文本。需要配合使用，且每一个匿名化接口的调用需要有一个对应的反匿名化接口的调用，要不然会有内存泄漏。可以先批量调用匿名化接口，处理完所有匿名化的文本后，再批量调用反匿名化接口。
匿名化接口返回的二进制帧数据格式和反匿名化接口接收的二进制帧数据格式是一样的，下面有其具体定义。需要注意的是，配对的匿名化和反匿名化接口调用需要使用相同的maskMeta。

### 二进制帧数据格式（均为小端序 little-endian）：
1) 4 字节无符号整型 N：后续“文本”的 UTF-8 字节长度
2) N 字节：UTF-8 文本字节（在 mask_text 中为 masked text；在 restore_text 请求中为 masked text）
3) 剩余全部字节：`maskMeta` 原始 bytes（在 mask_text 响应中返回；在 restore_text 请求中携带）
**备注**：`maskMeta` 是OneAIFW服务内部使用的不透明的一段二进制数据，表现为bytes，由匿名化接口返回，调用者无需关心其具体内容。

### 匿名化接口（生成 masked text 与 maskMeta）
- 方法/路径：POST `/api/mask_text`
- 请求 Content-Type：`application/json`
- 请求体字段：
  - `text` (string, 必填)：原始输入文本
  - `language` (string, 可选)：语言提示（如 `en`、`zh`）；若省略，服务端自动检测
- 响应 Content-Type：`application/octet-stream`
- 响应体：二进制帧，携带 masked text 与 `maskMeta` 原始 bytes

### 反匿名化接口（输入 masked text 与 maskMeta 得到反匿名化后的文本）
- 方法/路径：POST `/api/restore_text`
- 请求 Content-Type：`application/octet-stream`
- 请求体：二进制帧（见上），包含 masked text 与对应的 `maskMeta` 原始 bytes
- 响应 Content-Type：`text/plain; charset=utf-8`
- 响应体：反匿名化后的纯文本字符串

### Python 使用示例
```python
import requests

base = "http://127.0.0.1:8844"

# 1) 调用 mask_text（JSON 请求 → 二进制响应）
r = requests.post(f"{base}/api/mask_text", json={"text": "张三电话13812345678", "language": "zh"})
r.raise_for_status()
blob = r.content

if len(blob) < 4:
    raise RuntimeError("invalid response")
text_len = int.from_bytes(blob[0:4], byteorder="little", signed=False)
masked_text = blob[4:4+text_len].decode("utf-8")
mask_meta_bytes = blob[4+text_len:]
print("masked:", masked_text)

# 2) 调用 restore_text（二进制请求 → 文本响应）
text_bytes = masked_text.encode("utf-8")
payload = len(text_bytes).to_bytes(4, "little") + text_bytes + mask_meta_bytes
r2 = requests.post(f"{base}/api/restore_text", data=payload, headers={"Content-Type": "application/octet-stream"})
r2.raise_for_status()
print("restored:", r2.text)
```

### Node.js（fetch）示例
```js
// 需要 Node 18+ 或自行引入 fetch polyfill
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

## 附注
- `maskMeta` 的内容在服务端是 `placeholdersMap` 的 UTF-8 JSON 序列化结果；客户端无需理解其结构，按原样传回 `restore_text` 即可。
- 若启用鉴权，请在请求头携带 `X-API-Key`。
