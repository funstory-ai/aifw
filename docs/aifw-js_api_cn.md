# aifw-js API 接口文档

本文档说明 `libaifw.js` 文件中导出的所有接口函数。

## 目录

- [初始化与清理](#初始化与清理)
- [语言检测](#语言检测)
- [文本匿名化](#文本匿名化)
- [文本恢复](#文本恢复)
- [批量处理](#批量处理)
- [PII 片段获取](#pii-片段获取)
- [数据类型](#数据类型)

---

## 初始化与清理

### `init(options)`

初始化 aifw-js 库，加载必要的 WASM 模块和 NER 模型，并创建匿名化会话。

**参数：**

- `options` (Object, 可选): 初始化配置，支持两种资源管理模式，并可分别对「模型」与「ORT 运行时」进行配置，同时可以控制按实体类型是否执行匿名化
  - `mode` (String, 可选): 整体模式（默认应用到子项），可选 `'managed' | 'customize'`
  - `models` (Object, 可选): 模型资源设置
    - `mode` (String, 可选): `'managed' | 'customize'`
    - `modelsBase` (String, 可选): 当 `mode='customize'` 时必须指定模型根路径（如 `'/models/'`）
    - `enModelId` (String, 可选): 英文 NER 模型 ID（默认 `'funstory-ai/neurobert-mini'`）
    - `zhModelId` (String, 可选): 中文 NER 模型 ID（默认 `'ckiplab/bert-tiny-chinese-ner'`）
  - `ort` (Object, 可选): ONNXRuntime Web (ORT) WASM 设置
    - `mode` (String, 可选): `'managed' | 'customize'`
    - `wasmBase` (String, 可选): ORT wasm 目录（包含 `ort-wasm-simd*.wasm` 等文件）
    - `threads` (Number, 可选): 线程数（默认根据 `navigator.hardwareConcurrency` 决定）
    - `simd` (Boolean, 可选): 是否启用 SIMD（默认 `true`）
  - `maskConfig` (Object, 可选): 按实体类型控制是否进行匿名化（占位符替换 + 写入元数据），所有字段均为可选布尔值：
    - `maskAddress` (Boolean): 是否匿名化物理地址（PHYSICAL_ADDRESS），缺省值是false。
    - `maskEmail` (Boolean): 是否匿名化邮箱地址（EMAIL_ADDRESS），缺省值是true。
    - `maskOrganization` (Boolean): 是否匿名化组织/公司名（ORGANIZATION），缺省值是true。
    - `maskUserName` (Boolean): 是否匿名化人名/用户名（USER_MAME），缺省值是true。
    - `maskPhoneNumber` (Boolean): 是否匿名化电话号码（PHONE_NUMBER），缺省值是true。
    - `maskBankNumber` (Boolean): 是否匿名化银行卡号（BANK_NUMBER），缺省值是true。
    - `maskPayment` (Boolean): 是否匿名化支付相关信息（PAYMENT），缺省值是true。
    - `maskVerificationCode` (Boolean): 是否匿名化验证码（VERIFICATION_CODE），缺省值是true。
    - `maskPassword` (Boolean): 是否匿名化密码（PASSWORD），缺省值是true。
    - `maskRandomSeed` (Boolean): 是否匿名化随机种子（RANDOM_SEED），缺省值是true。
    - `maskPrivateKey` (Boolean): 是否匿名化私钥（PRIVATE_KEY），缺省值是true。
    - `maskUrl` (Boolean): 是否匿名化 URL（URL_ADDRESS），缺省值是true。
    - `maskAll` (Boolean): 是否匿名化所有的实体类型，全开或者全关，覆盖上面所有设置，无缺省值。

兼容性（向后兼容）：
- 仍支持旧参数：`wasmBase`（等价于 `ort.wasmBase` 的本地/自定义路径）、`modelsBase`（等价于 `models.modelsBase` 的本地/自定义路径）。
- managed mode，且传递了自定义资源时，打 warning 日志，然后使用 managed 模式，忽略自定义资源。

**返回值：**

- `Promise<void>`: 初始化完成后解析

**示例：**

```javascript
import { init } from './libaifw.js';

// 1) default：全部交给库与上游托管（自动从外部下载），使用核心默认的匿名化策略
await init();

// 2) local：本地调试，模型与 ORT wasm 均从本地路径加载
await init({
  mode: 'local',
  models: { modelsBase: '/assets/models/' },    // 模型根目录
  ort: { wasmBase: '/assets/wasm/' }           // ORT wasm 目录
});

// 3) customize：完全自定义各资源路径（需要显式提供）
await init({
  models: {
    mode: 'customize',
    modelsBase: 'https://cdn.example.com/oneaifw-models'
  },
  ort: {
    mode: 'customize',
    wasmBase: 'https://cdn.example.com/onnxruntime-wasm'
  }
});

// 4) 混合：模型自定义，ORT 使用默认 CDN/内置路径
await init({
  models: { mode: 'customize', modelsBase: '/my-models' },
  ort: { mode: 'default' } // 不设路径则走上游默认
});

// 5) 控制按实体类型是否匿名化（例如：只匿名化邮箱和手机号，地址保留原文）
await init({
  maskConfig: {
    maskAddress: false,
    maskEmail: true,
    maskPhoneNumber: true
  }
});
```

**说明：**

- 此函数会加载核心 WASM 库 (`liboneaifw_core.wasm`)，核心库固定从包内路径加载，无需配置
- 自动加载英文和中文 NER 模型：
  - 英文模型：`funstory-ai/neurobert-mini`
  - 中文模型：`ckiplab/bert-tiny-chinese-ner`
- 如果中文模型加载失败，会回退使用英文模型
- 必须在使用其他功能之前调用此函数
- 匿名化策略：
  - 核心库内部有一套默认的按实体类型匿名化策略（例如默认不匿名化地址，其他类型全部匿名化）
  - `maskConfig` 中的布尔开关会在默认策略的基础上进行「覆盖」：
    - 传入 `true`：强制对该类型执行匿名化
    - 传入 `false`：强制对该类型不执行匿名化（保留原文，不写入匿名化元数据）
    - 未传：沿用核心默认策略

托管模式（managed）行为：
- 资源来源：从仓库的 `models/` 与 `wasm/` 子目录下载（参考仓库入口：[OneAIFW-Assets](https://github.com/funstory-ai/OneAIFW-Assets/tree/main)）。
- 源可用性判断：优先读取仓库根目录的 `hello.json`，取其中 `version` 字段，若其值不小于库内的 `OneAIFW_ASSETS_VERSION`，则该源可用。
- 完整性校验：下载英文与中文 NER 的 `onnx/model_quantized.onnx` 以及 ORT 的 wasm 文件后，计算其 SHA3-256，与库内的 `EN_MODEL_SHA3_256`、`ZH_MODEL_SHA3_256`、`ORT_WASM_SHA3_256` 比对，不一致则报错终止。
- 缓存：利用浏览器 Cache Storage（若可用）进行缓存，加速后续加载。

---

### `deinit()`

清理资源，释放 WASM 模块和模型。

**参数：**

无

**返回值：**

- `Promise<void>`: 清理完成后解析

**示例：**

```javascript
import { deinit } from './libaifw.js';

await deinit();
```

**说明：**

- 销毁当前会话
- 关闭 WASM 核心模块
- 清理 NER 管道和模型引用
- 调用后需要重新调用 `init()` 才能继续使用

---

## 语言检测

### `detectLanguage(text)`

检测文本的语言和脚本类型（简体/繁体）。

**参数：**

- `text` (String): 要检测的文本

**返回值：**

- `Promise<Object>`: 检测结果对象
  - `lang` (String): 检测到的语言代码（如 `'zh'`, `'en'`, `'other'`）
  - `script` (String | null): 对于中文，返回 `'Hans'`（简体）或 `'Hant'`（繁体），其他语言为 `null`
  - `confidence` (Number): 置信度（0-1 之间）
  - `method` (String): 检测方法（`'heuristic'` 或 `'opencc'`）

**示例：**

```javascript
import { detectLanguage } from './libaifw.js';

// 检测简体中文
const result1 = await detectLanguage('你好，世界');
// { lang: 'zh', script: 'Hans', confidence: 0.95, method: 'opencc' }

// 检测繁体中文
const result2 = await detectLanguage('你好，世界');
// { lang: 'zh', script: 'Hant', confidence: 0.95, method: 'opencc' }

// 检测英文
const result3 = await detectLanguage('Hello, world');
// { lang: 'en', script: null, confidence: 0.9, method: 'heuristic' }
```

**说明：**

- 使用启发式方法快速检测语言类型
- 对于中文，会进一步判断是简体还是繁体
- 如果启发式方法无法确定，会使用 OpenCC 进行更精确的检测
- 支持自动语言检测，可在 `maskText` 和 `getPiiSpans` 中使用 `'auto'` 作为语言参数

---

## 文本匿名化

### `maskText(inputText, language)`

对文本中的敏感信息（PII）进行匿名化处理。

**参数：**

- `inputText` (String): 要匿名化的原始文本
- `language` (String, 可选): 文本语言代码，支持以下值：
  - `'auto'` 或 `null` 或 `''`: 自动检测语言（默认）
  - `'en'`: 英文
  - `'zh'`, `'zh-CN'`, `'zh-Hans'`: 简体中文
  - `'zh-TW'`, `'zh-HK'`, `'zh-Hant'`: 繁体中文
  - 其他语言代码（如 `'ja'`, `'ko'`, `'fr'`, `'de'`, `'ru'`, `'es'`, `'it'`, `'ar'`, `'pt'`）

**返回值：**

- `Promise<Array>`: 返回一个包含两个元素的数组
  - `[0]` (String): 匿名化后的文本
  - `[1]` (Uint8Array): 匿名化元数据，用于后续恢复原始文本

**示例：**

```javascript
import { maskText } from './libaifw.js';

// 自动检测语言
const [masked, maskMeta] = await maskText('我的邮箱是 user@example.com', 'auto');
console.log(masked); // 我的邮箱是 [EMAIL]

// 指定语言
const [masked2, maskMeta2] = await maskText('Contact me at user@example.com', 'en');
console.log(masked2); // Contact me at [EMAIL]

// 保存元数据以便后续恢复
// maskMeta 是一个 Uint8Array，可以保存到文件或数据库
```

**说明：**

- 使用 NER（命名实体识别）模型识别文本中的敏感信息
- 支持多种实体类型：邮箱、电话、人名、地址等
- 对于简体中文，会自动转换为繁体进行 NER 识别，然后转换回简体
- 返回的 `maskMeta` 必须保存，用于后续调用 `restoreText()` 恢复原始文本
- 如果未初始化或 NER 管道未就绪，会抛出错误

---

## 文本恢复

### `restoreText(maskedText, maskMeta)`

使用匿名化元数据将匿名化后的文本恢复为原始文本。

**参数：**

- `maskedText` (String): 匿名化后的文本
- `maskMeta` (Uint8Array | ArrayLike): 匿名化元数据，由 `maskText()` 返回

**返回值：**

- `Promise<String>`: 恢复后的原始文本

**示例：**

```javascript
import { maskText, restoreText } from './libaifw.js';

// 匿名化文本
const [masked, maskMeta] = await maskText('我的邮箱是 user@example.com', 'zh-CN');
console.log(masked); // 我的邮箱是 [EMAIL]

// 恢复文本
const restored = await restoreText(masked, maskMeta);
console.log(restored); // 我的邮箱是 user@example.com
```

**说明：**

- `maskMeta` 必须与 `maskText()` 返回的元数据完全一致
- 如果元数据无效或格式错误，会抛出错误
- 恢复后的文本应该与原始输入文本完全一致

---

## 批量处理

### `maskTextBatch(textAndLanguageArray)`

批量对多个文本进行匿名化处理。

**参数：**

- `textAndLanguageArray` (Array): 文本数组，每个元素可以是：
  - `String`: 纯文本字符串，将使用自动语言检测
  - `Object`: 包含以下属性的对象
    - `text` (String): 要匿名化的文本
    - `language` (String, 可选): 语言代码，如果为 `null`、`''` 或 `'auto'`，则自动检测

**返回值：**

- `Promise<Array>`: 结果数组，每个元素是一个对象：
  - `text` (String): 匿名化后的文本
  - `maskMeta` (Uint8Array): 匿名化元数据

**示例：**

```javascript
import { maskTextBatch } from './libaifw.js';

// 使用字符串数组（自动检测语言）
const results1 = await maskTextBatch([
  '我的邮箱是 user@example.com',
  'Contact me at user@example.com'
]);
// [
//   { text: '我的邮箱是 [EMAIL]', maskMeta: Uint8Array(...) },
//   { text: 'Contact me at [EMAIL]', maskMeta: Uint8Array(...) }
// ]

// 使用对象数组（指定语言）
const results2 = await maskTextBatch([
  { text: '我的邮箱是 user@example.com', language: 'zh-CN' },
  { text: 'Contact me at user@example.com', language: 'en' }
]);
```

**说明：**

- 每个文本的语言检测和匿名化处理是独立的
- 返回的结果数组与输入数组的顺序一致

---

### `restoreTextBatch(textAndMaskMetaArray)`

批量恢复多个匿名化文本。

**参数：**

- `textAndMaskMetaArray` (Array): 对象数组，每个对象包含：
  - `text` (String): 匿名化后的文本
  - `maskMeta` (Uint8Array | ArrayLike): 匿名化元数据

**返回值：**

- `Promise<Array>`: 结果数组，每个元素是一个对象：
  - `text` (String): 恢复后的原始文本

**示例：**

```javascript
import { maskTextBatch, restoreTextBatch } from './libaifw.js';

// 批量匿名化
const maskedResults = await maskTextBatch([
  '我的邮箱是 user@example.com',
  'Contact me at user@example.com'
]);

// 批量恢复
const restoredResults = await restoreTextBatch(maskedResults);
// [
//   { text: '我的邮箱是 user@example.com' },
//   { text: 'Contact me at user@example.com' }
// ]
```

**说明：**

- 每个文本的恢复是独立的
- 返回的结果数组与输入数组的顺序一致

---

## PII 片段获取

### `getPiiSpans(inputText, language)`

获取文本中所有 PII（个人身份信息）片段的位置和类型信息。

**参数：**

- `inputText` (String): 要分析的文本
- `language` (String, 可选): 文本语言代码，支持的值与 `maskText()` 相同
  - `'auto'` 或 `null` 或 `''`: 自动检测语言（默认）

**返回值：**

- `Promise<Array<MatchedPIISpan>>`: PII 片段数组，每个元素是 `MatchedPIISpan` 对象

**示例：**

```javascript
import { getPiiSpans } from './libaifw.js';

const spans = await getPiiSpans('我的邮箱是 user@example.com，电话是 13800138000', 'zh-CN');
console.log(spans);
// [
//   MatchedPIISpan {
//     entity_id: 1,
//     entity_type: 2,
//     matched_start: 5,
//     matched_end: 22
//   },
//   MatchedPIISpan {
//     entity_id: 2,
//     entity_type: 3,
//     matched_start: 25,
//     matched_end: 36
//   }
// ]

// 获取每个片段对应的文本
spans.forEach(span => {
  const text = inputText.substring(span.matched_start, span.matched_end);
  console.log(`PII at [${span.matched_start}, ${span.matched_end}): ${text}`);
});
```

**说明：**

- 返回maskConfig允许的检测到的 PII 片段，但不进行匿名化处理
- 可以用于分析文本中包含哪些类型的敏感信息
- 对于简体中文，会自动转换为繁体进行识别，然后转换回简体坐标
- 如果未初始化或 NER 管道未就绪，会抛出错误

---

## 数据类型

### `MatchedPIISpan`

表示一个匹配到的 PII 片段。

**属性：**

- `entity_id` (Number): 实体 ID（无符号 32 位整数）
- `entity_type` (Number): 实体类型（0-255 的整数）
- `matched_start` (Number): 匹配开始位置（字符索引，从 0 开始）
- `matched_end` (Number): 匹配结束位置（字符索引，不包含）

**示例：**

```javascript
import { getPiiSpans } from './libaifw.js';

const spans = await getPiiSpans('Email: user@example.com', 'en');
const span = spans[0];

console.log(span.entity_id);      // 1
console.log(span.entity_type);    // 2
console.log(span.matched_start);  // 7
console.log(span.matched_end);    // 24

// 提取匹配的文本
const matchedText = 'Email: user@example.com'.substring(
  span.matched_start,
  span.matched_end
);
console.log(matchedText); // 'user@example.com'
```

**说明：**

- `matched_start` 和 `matched_end` 是基于原始输入文本的字符索引
- `matched_end` 是排他的（不包含该位置的字符）
- 可以使用 `substring(matched_start, matched_end)` 提取匹配的文本片段

---

## 使用流程示例

### 基本使用流程

```javascript
import { init, maskText, restoreText, deinit } from './libaifw.js';

async function example() {
  try {
    // 1. 初始化
    await init({ modelsBase: '/models/', wasmBase: '/wasm/' }); // 兼容旧参数：分别映射为 models.modelsBase 与 ort.wasmBase

    // 2. 匿名化文本
    const originalText = '我的邮箱是 user@example.com';
    const [masked, maskMeta] = await maskText(originalText, 'zh-CN');
    console.log('匿名化后:', masked);

    // 3. 保存匿名化元数据（实际应用中应保存到数据库或文件）
    // const maskMetaBase64 = btoa(String.fromCharCode(...maskMeta));

    // 4. 恢复文本
    const restored = await restoreText(masked, maskMeta);
    console.log('恢复后:', restored);

    // 5. 清理资源
    await deinit();
  } catch (error) {
    console.error('错误:', error);
  }
}

example();
```

### 批量处理示例

```javascript
import { init, maskTextBatch, restoreTextBatch, deinit } from './libaifw.js';

async function batchExample() {
  try {
    await init();

    // 批量匿名化
    const texts = [
      { text: '我的邮箱是 user@example.com', language: 'zh-CN' },
      { text: 'Contact me at user@example.com', language: 'en' },
      '自动检测语言的文本 user@example.com'
    ];

    const maskedResults = await maskTextBatch(texts);
    console.log('批量匿名化结果:', maskedResults);

    // 批量恢复
    const restoredResults = await restoreTextBatch(maskedResults);
    console.log('批量恢复结果:', restoredResults);

    await deinit();
  } catch (error) {
    console.error('错误:', error);
  }
}

batchExample();
```

### 获取 PII 片段示例

```javascript
import { init, getPiiSpans, deinit } from './libaifw.js';

async function analyzeExample() {
  try {
    await init();

    const text = '我的邮箱是 user@example.com，电话是 13800138000';
    const spans = await getPiiSpans(text, 'zh-CN');

    console.log(`检测到 ${spans.length} 个 PII 片段:`);
    spans.forEach((span, index) => {
      const piiText = text.substring(span.matched_start, span.matched_end);
      console.log(`${index + 1}. 类型: ${span.entity_type}, 位置: [${span.matched_start}, ${span.matched_end}), 内容: ${piiText}`);
    });

    await deinit();
  } catch (error) {
    console.error('错误:', error);
  }
}

analyzeExample();
```

---

## 错误处理

所有异步函数都可能抛出错误，建议使用 `try-catch` 进行错误处理：

```javascript
try {
  await init();
  const [masked, maskMeta] = await maskText('text', 'en');
} catch (error) {
  console.error('操作失败:', error.message);
  // 常见错误：
  // - 'AIFW not initialized': 未调用 init()
  // - 'invalid session handle': 会话无效
  // - 'NER pipeline not ready': NER 模型未加载
  // - 'mask failed rc=...': 匿名化操作失败
  // - 'restore failed rc=...': 恢复操作失败
}
```

---

## 注意事项

1. **初始化顺序**：必须在使用任何其他功能之前调用 `init()`
2. **元数据保存**：`maskText()` 返回的 `maskMeta` 必须妥善保存，否则无法恢复原始文本
3. **语言检测**：使用 `'auto'` 时，语言检测需要一定时间，指定语言可以提高性能
4. **资源清理**：在应用退出或不再需要时，建议调用 `deinit()` 释放资源
5. **并发安全**：库支持并发调用，但建议在单次初始化后复用
6. **中文处理**：简体中文会自动转换为繁体进行 NER 识别，然后转换回简体，确保坐标正确

---

## 版本信息

本文档基于 `libaifw.js` 的当前实现编写。如有更新，请参考源代码。

