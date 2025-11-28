This sub‑project provides the OneAIFW Python backend and CLI, built on Presidio and LiteLLM. It exposes a FastAPI HTTP service and a simple CLI for masking/restoring text around LLM calls.

## Getting Started (py-origin)
It anonymizes sensitive data before LLM calls and restores it afterward. See the root `README.md` for global prerequisites (Zig/Rust/Node/pnpm). Below are minimal steps to run the service and demos to call its APIs.

### Clone and create venv
```bash
git clone https://github.com/funstory-ai/aifw.git
cd aifw
cd py-origin
python -m venv .venv
source .venv/bin/activate  # Windows: .venv\\Scripts\\activate
```

### Install dependencies
```bash
cd py-origin
pip install -r services/requirements.txt
pip install -r cli/requirements.txt
python -m spacy download en_core_web_sm
python -m spacy download zh_core_web_sm
python -m spacy download xx_ent_wiki_sm
```

### Prepare config and LLM API key file
The default aifw.yaml is in assets directory, you can modify this file for yourself.

```bash
cd py-origin
mkdir -p ~/.aifw
cp assets/aifw.yaml ~/.aifw/aifw.yaml
# edit ~/.aifw/aifw.yaml and set api_key_file to your LLM API key JSON
```

### Launch HTTP server
Authentication uses the standard `Authorization` header. Configure the HTTP API key via env or CLI:
```bash
# Env var (example key)
export AIFW_HTTP_API_KEY=8H234B
```

Start the server (logs go to `~/.aifw/`):
```bash
cd py-origin
python -m aifw launch  # add --http-api-key KEY to override env
```
You should see output like:
```
aifw is running at http://localhost:8844.
logs: ~/.aifw/aifw_server-2025-08.log
```

## CLI demos for API usage

The CLI calls the HTTP server to mask PII, optionally call an LLM, and restore text. Use `--http-api-key` if you set `AIFW_HTTP_API_KEY` on the server.

```bash
cd py-origin
python -m aifw call "请把如下文本翻译为中文: My email address is test@example.com, and my phone number is 18744325579."
# With explicit HTTP API key:
python -m aifw call --http-api-key 8H234B "..."
```

You can override the LLM API key file per call using `--api-key-file`:
```bash
cd py-origin
python -m aifw call --api-key-file /path/to/api-keys/your-key.json "..."
```

### Direct in-process call (no HTTP)
```bash
cd py-origin
python -m aifw direct_call "请把如下文本翻译为中文: My email address is test@example.com, and my phone number is 18744325579."
```

You can also switch provider dynamically per call:
```bash
cd py-origin
python -m aifw direct_call --api-key-file /path/to/api-keys/your-key.json "..."
```

### Single mask + restore (mask_text → restore_text)
Call mask and then restore a single text via the HTTP APIs:

```bash
# One command pipeline (mask → restore)
python -m aifw mask_restore "text 1" --http-api-key 8H234B
```

### Batch mask + restore (mask_text_batch → restore_text_batch)
Mask and restore a list of texts using the batch mode interface:

```bash
# One command pipeline (batch mask → batch restore)
python -m aifw mask_restore_batch "text 1" "text 2" --http-api-key 8H234B
```

### Multi mask, then one restore (many × mask_text → one × restore_text_batch)
Call `mask_text` multiple times, then restore all at once:

```bash
# Call mask_text individually for multiple items, then restore all at once
python -m aifw multi_mask_one_restore "text 1" "text 2" --http-api-key 8H234B
```

### Stop the server
```bash
cd py-origin
python -m aifw stop
```

### API documentation

See `docs/oneaifw_services_api.md` for all API interfaces, request/response formats, and curl examples. All responses include `output` and `error`. The `Authorization` header accepts either `KEY` or `Bearer KEY` formats.


## Docker images for py-origin (spaCy profiles)

You can build different Docker images for the `py-origin` service with various spaCy model profiles via `--build-arg SPACY_PROFILE=...`:

- `minimal` (default): en_core_web_sm, zh_core_web_sm, xx_ent_wiki_sm  
- `fr`: minimal + fr_core_news_sm  
- `de`: minimal + de_core_news_sm  
- `ja`: minimal + ja_core_news_sm  
- `multi`: minimal + fr/de/ja  

From the repo root:

```bash
cd py-origin

# Build minimal
docker build -t oneaifw:minimal .

# Build French / German / Japanese
docker build --build-arg SPACY_PROFILE=fr -t oneaifw:fr .
docker build --build-arg SPACY_PROFILE=de -t oneaifw:de .
docker build --build-arg SPACY_PROFILE=ja -t oneaifw:ja .

# Build multi-language
docker build --build-arg SPACY_PROFILE=multi -t oneaifw:multi .
```
