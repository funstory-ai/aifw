# **Note: This file is not for user, this file will be deleted**

# OneAIFW - Local Presidio-based Reversible Anonymization Framework

This repository provides a local Presidio-based service (OneAIFW) with:
- FastAPI backend using `presidio-analyzer` and `presidio-anonymizer`
- Reversible placeholders and unified API for anonymize → LLM → restore
- Tkinter desktop UI client
- Browser extension (Chrome/Edge MV3)
- Dockerfile + docker-compose for easy local deployment

## Quickstart - Service (Docker)
Build profiles for spaCy models via `--build-arg SPACY_PROFILE=...`:

- minimal (default): en_core_web_sm, zh_core_web_sm, xx_ent_wiki_sm
- fr: minimal + fr_core_news_sm
- de: minimal + de_core_news_sm
- ja: minimal + ja_core_news_sm
- multi: minimal + fr/de/ja

```bash
# Build minimal (default)
docker build -t oneaifw:minimal .

# Build French / German / Japanese
docker build --build-arg SPACY_PROFILE=fr -t oneaifw:fr .
docker build --build-arg SPACY_PROFILE=de -t oneaifw:de .
docker build --build-arg SPACY_PROFILE=ja -t oneaifw:ja .

# Build multi-language
docker build --build-arg SPACY_PROFILE=multi -t oneaifw:multi .

# Run (mount host work dir with config/logs and your api keys)
docker run --rm -p 8844:8844 \
  -v $HOME/.aifw:/data/aifw \
  oneaifw:minimal
```

The container copies `/opt/aifw/assets/aifw.yaml` to `/data/aifw/aifw.yaml` if missing. Edit it to point to your API key file (not included in the image).

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
# Unified call examples (module name changed to aifw)
python -m aifw direct_call --api-key-file /path/to/api-key.json "Hello"
python -m aifw launch --work-dir ~/.aifw --log-dest file
python -m aifw call --url http://127.0.0.1:8844 --api-key-file /path/to/api-key.json "Hello"
python -m aifw stop --work-dir ~/.aifw
```

## Browser Extension
Load `browser_extension` as unpacked extension in Chrome/Edge developer mode.

## Notes
- If you still want the HTTP service, start it as shown above; UI/CLI work with the in-process API and do not require the HTTP server.
- spaCy 模型：首次使用请安装 `en_core_web_sm`。安装：`python -m spacy download en_core_web_sm`（在对应 venv 中执行）。
- LLM 网关（OpenAI 兼容）：在配置 JSON 中提供 `openai-api-key` / `openai-base-url` / `openai-model`，CLI 通过 `--api-key-file` 读取。
- The anonymization uses placeholders that are robust to LLM round-trips.

## Local fake LLM
The local fake LLM is just echo the chat text to client. Launch the local fake LLM by bellow command.
```bash
python -m uvicorn services.fake_llm.echo_server:app --host 127.0.0.1 --port 8801
```

## Validate anonymization correctness (using --stage anonymized)

Use the provided test inputs under `test/` and the local fake LLM (echo) to verify the anonymization output exactly matches the expected anonymized text.

1) Generate anonymized text (no LLM, no restore) and compare to expected:
```bash
cat test/test_en_pii.txt | \
  python -m aifw direct_call \
    --log-dest stdout \
    --api-key-file assets/local-fake-llm-apikey.json \
    --stage anonymized - > out.anonymized.txt

diff -u test/test_en_pii.anonymized.expected.txt out.anonymized.txt
```

2) Send anonymized text via fake LLM echo (still no restore) and compare to expected:
```bash
cat test/test_en_pii.txt | \
  python -m aifw direct_call \
    --log-dest stdout \
    --api-key-file assets/local-fake-llm-apikey.json \
    --stage anonymized_via_llm - > out.anonymized.llm.txt

diff -u test/test_en_pii.anonymized.expected.txt out.anonymized.llm.txt
```

3) Optional: verify full pipeline (anonymize → LLM → restore) returns the original text:
```bash
cat test/test_en_pii.txt | \
  python -m aifw direct_call \
    --log-dest stdout \
    --api-key-file assets/local-fake-llm-apikey.json \
    --stage restored - > out.restored.txt

diff -u test/test_en_pii.txt out.restored.txt
```
