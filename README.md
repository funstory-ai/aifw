# OneAIFW - Local Presidio-based Reversible Anonymization Framework

This repository provides a local Presidio-based service (OneAIFW) with:
- FastAPI backend using `presidio-analyzer` and `presidio-anonymizer`
- Reversible placeholders and unified API for anonymize → LLM → restore
- Tkinter desktop UI client
- Browser extension (Chrome/Edge MV3)
- Dockerfile + docker-compose for easy local deployment

## Quickstart - Service
```bash
cd services
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
uvicorn app.main:app --host 127.0.0.1 --port 8000 --reload
```

Or with Docker:
```bash
cd services
docker build -t oneaifw-presidio-service .
docker run -p 8000:8000 -e API_KEY=changeme-please oneaifw-presidio-service
```

## Unified API
- In-process: `services/app/one_aifw_api.py` (class `OneAIFWAPI`)
- Local wrapper: `services/app/local_api.py` exposes `call(text, api_key_file, model, temperature, language)`
- HTTP endpoint: `POST /api/call` with body `{ text, apiKeyFile, model, temperature, language }`

## UI
```bash
cd ui
pip install -r requirements.txt
python desktop_app.py
```

## CLI
```bash
cd cli
# Basic anonymize/restore/analyze utils
python -m oneaifw_cli anonymize --text "My email is test@example.com"
echo "My phone is 13800001111" | python -m oneaifw_cli anonymize -
python -m oneaifw_cli analyze --text "Contact me at test@example.com"
python -m oneaifw_cli restore --text "Hello __PII_EMAIL_ADDRESS_abcd1234__" -p '{"__PII_EMAIL_ADDRESS_abcd1234__":"test@example.com"}'

# Unified LLM call (anonymize → LLM → restore)
python -m oneaifw_cli call --api-key-file ../../api-keys/glm-free-apikey.json "My email is test@example.com, My phone number is 18744325579"
# Optional model/temperature/language
python -m oneaifw_cli call --api-key-file ../../api-keys/glm-free-apikey.json --model glm-4 --temperature 0.0 --language en "Hello"
```

## Browser Extension
Load `browser_extension` as unpacked extension in Chrome/Edge developer mode.

## Notes
- If you still want the HTTP service, start it as shown above; UI/CLI work with the in-process API and do not require the HTTP server.
- spaCy 模型：首次使用请安装 `en_core_web_sm`。安装：`python -m spacy download en_core_web_sm`（在对应 venv 中执行）。
- LLM 网关（OpenAI 兼容）：在配置 JSON 中提供 `openai-api-key` / `openai-base-url` / `openai-model`，CLI 通过 `--api-key-file` 读取。
- The anonymization uses placeholders that are robust to LLM round-trips.
