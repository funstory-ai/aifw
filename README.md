# OneAIFW - Local Presidio-based Reversible Anonymization Framework

This repository provides a local Presidio-based service (OneAIFW) with:
- FastAPI backend using `presidio-analyzer` and `presidio-anonymizer`
- Reversible translation-safe placeholders for anonymization
- Tkinter desktop UI client to call the service
- Browser extension (Chrome/Edge MV3) to anonymize selected text on web pages
- Dockerfile + docker-compose for easy local deployment

## Quickstart - Service
```bash
cd services/presidio_service
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
uvicorn app.main:app --host 127.0.0.1 --port 8000 --reload
```

Or with Docker:
```bash
cd services/presidio_service
docker build -t oneaifw-presidio-service .
docker run -p 8000:8000 -e API_KEY=changeme-please oneaifw-presidio-service
```

## Local API (in-process)
UI and CLI now call a local in-process API (`services/presidio_service/app/local_api.py`) directly, without HTTP.

## UI
```bash
cd ui
pip install -r requirements.txt
python desktop_app.py
```

## CLI
```bash
cd cli
python -m oneaifw_cli anonymize --text "My email is test@example.com"
echo "My phone is 13800001111" | python -m oneaifw_cli anonymize -
python -m oneaifw_cli analyze --text "Contact me at test@example.com"
python -m oneaifw_cli restore --text "Hello __PII_EMAIL_ADDRESS_abcd1234__" -p '{"__PII_EMAIL_ADDRESS_abcd1234__":"test@example.com"}'
```

## Browser Extension
Load `browser_extension` as unpacked extension in Chrome/Edge developer mode.

## Notes
- If you still want the HTTP service, start it as shown above; the UI/CLI will continue to work with the in-process API and do not require the HTTP server.
- spaCy 模型：首次使用请安装 `en_core_web_sm`，否则会报错找不到 `en_core_web_sm`。
  - 安装：`python -m spacy download en_core_web_sm`
  - 若使用虚拟环境，请在对应 venv 中执行安装命令。
- The anonymization uses placeholders that are robust to machine translation/LLM round-trips.
