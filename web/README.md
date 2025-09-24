# AIFW Web Module

AIFW Web 模块提供了一个基于 Web 的界面来演示 OneAIFW 项目的隐私保护功能。

## 功能特性

- 🌐 **Web 界面**：直观的 Web 界面介绍 AIFW 项目
- 🔍 **敏感信息分析**：检测文本中的敏感信息实体
- 🎭 **匿名化处理**：将敏感信息替换为占位符
- 🔄 **文本恢复**：将匿名化文本恢复为原始内容
- 🌍 **多语言支持**：支持中文和英文文本处理
- 📱 **响应式设计**：适配桌面和移动设备

## 快速开始

### 1. 安装依赖

```bash
pip install -r ../py-origin/services/requirements.txt
pip install -r requirements.txt
```

### 2. 启动服务

```bash
python run.py
```

或者直接运行：

```bash
python app.py
```

### 3. 访问界面

打开浏览器访问：http://localhost:5000

## API 接口

### 健康检查
```
GET /api/health
```

### 分析敏感信息
```
POST /api/analyze
Content-Type: application/json

{
    "text": "要分析的文本",
    "language": "zh"
}
```

### 匿名化处理
```
POST /api/mask
Content-Type: application/json

{
    "text": "要匿名化的文本",
    "language": "zh"
}
```

### 恢复文本
```
POST /api/restore
Content-Type: application/json

{
    "text": "匿名化文本",
    "placeholders_map": {
        "PII_EMAIL_12345678__": "test@example.com"
    }
}
```

### 调用 LLM（需要配置 API 密钥）
```
POST /api/call
Content-Type: application/json

{
    "text": "要处理的文本",
    "api_key_file": "/path/to/api-key.json",
    "model": "gpt-4o-mini",
    "temperature": 0.0
}
```

## 项目结构

```
web/
├── app.py              # Flask 应用主文件
├── run.py              # 启动脚本
├── requirements.txt    # Python 依赖
├── README.md          # 说明文档
├── templates/         # HTML 模板
│   └── index.html     # 主页面
└── static/           # 静态资源
    ├── css/
    │   └── style.css  # 样式文件
    └── js/
        └── app.js     # JavaScript 文件
```

## 依赖说明

- **Flask**: Web 框架
- **requests**: HTTP 请求库
- **py-origin 模块**: AIFW 核心功能（需要从上级目录导入）

## 注意事项

1. 确保 `py-origin` 目录在项目根目录下
2. 首次运行可能需要安装 spaCy 语言模型
3. LLM 功能需要配置有效的 API 密钥文件
4. 建议在虚拟环境中运行

## 故障排除

### 导入错误
如果遇到 `ImportError`，请确保：
- 在正确的目录下运行
- `py-origin` 目录存在且可访问
- 已安装所有必要的依赖

### 服务不可用
如果 AIFW 服务不可用：
- 检查 `py-origin` 目录结构
- 确保所有依赖已正确安装
- 查看控制台错误信息

## 开发说明

### 添加新功能
1. 在 `app.py` 中添加新的路由
2. 在 `templates/index.html` 中添加 UI 元素
3. 在 `static/js/app.js` 中添加前端逻辑
4. 在 `static/css/style.css` 中添加样式

### 自定义样式
修改 `static/css/style.css` 文件来自定义界面样式。

### 添加新的 API 端点
在 `app.py` 中添加新的路由函数，遵循现有的模式。
