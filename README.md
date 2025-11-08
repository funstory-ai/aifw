OneAIFW
===

OneAIFW is a local, lightweight “AI firewall” that anonymizes sensitive data before sending it to LLMs, and restores it after responses.

- Core engine: Zig + Rust (WASM and native)
- Frontend library: `@oneaifw/aifw-js` (Transformers.js + our WASM)
- Demos: Web app, Browser Extension
- Backend service based on presidio/LiteLLM: `py-origin` (FastAPI + Presidio/LiteLLM)

## What we protect for you

Privacy:
- Physical Address
- Email Address
- Name[optional]
- Phone
- Bank Account
- Paymant Information

Secrets:
- Verification Code
- Password 

Crypto:
- Seed
- Private Key
- Address

## Monorepo layout

- `core/` Zig core and pipelines (mask/restore)
- `libs/aifw-js/` JavaScript library used in browser and demos
- `apps/webapp/` Minimal browser demo (Vite)
- `browser_extension/` Chrome/Edge extension sample
- `py-origin/` Python backend service + CLI command (see its own README)
- `tests/transformer-js/` Transformers.js demo and model prep scripts

## Architecture

High‑level architecture (overview):

- aifw core library (Zig + Rust): provides the masking/restoring pipelines and regex/NER span fusion; builds to native and WASM for browser use.
- aifw-js (`@oneaifw/aifw-js`): browser library that runs NER with Transformers.js, converts spans to byte offsets, calls the WASM core to mask/restore, and exposes a friendly API (including batch and language‑aware masking).
- Backends and apps: `py-origin` HTTP service/CLI, `apps/webapp` demo, and `browser_extension`.

## Prerequisites

- Zig 0.15.1
- Rust toolchain (stable) + Cargo
  - `rustup target add wasm32-unknown-unknown`
- llvm tools: llvm-ar
  - Install llvm
  - Or add symbol link from the LLVM that is required when installing using Zig
      * In macOS: `ln -s $(brew --prefix llvm@20)/bin/llvm-ar /usr/local/bin/llvm-ar`
- Node.js 18+ and pnpm 9+
  - Install pnpm: `npm i -g pnpm`
- Python 3.10+ (for `py-origin` backend) and pip/venv

Verify versions:

```bash
zig version           # expect 0.15.1
rustc --version
cargo --version
node -v
pnpm -v
python3 --version
```

## Getting Started
OneAIFW lets you safely call external LLM providers by anonymizing sensitive data first, then restoring it after the model response. You can run it as a local HTTP service or use an in‑process CLI. Follow the steps below to get up and running quickly.

### Quick start

```bash
git clone https://github.com/funstory-ai/aifw.git
cd aifw
```

1) Build the aifw core library (native + WASM):

```bash
# From repo root
zig build
```

2) Install JS workspace dependencies (pnpm workspace):

```bash
pnpm -w install
```

3) Build the JavaScript library aifw-js (bundles and stages WASM/models), this library has a complete pipeline for mask/restore text with transformers.js:

```bash
pnpm -w --filter @oneaifw/aifw-js build
```

4) Run the web demo:

```bash
cd apps/webapp
pnpm dev
# open the printed local URL
```

5) Backend service and CLI based on presidio (see `py-origin/README.md`):

```bash
cd py-origin
python -m venv .venv && source .venv/bin/activate
pip install -r services/requirements.txt -r cli/requirements.txt
python -m aifw launch
```

The `py-origin` project is a standalone subproject. All of its development and usage documentation is now maintained in `py-origin/README.md`.

### Parameter precedence

For all configurable parameters, the resolution order is:

1. Command-line arguments
2. Environment variables
3. Config file (`aifw.yaml`)

For example, the LLM API key file is resolved as:

- CLI: `--api-key-file`
- Env: `AIFW_API_KEY_FILE`
- Config: `api_key_file` in `aifw.yaml`

The same precedence applies to port, logging options, etc.

## Building the aifw core library with Zig

We use Zig's build system to produce the native and WASM artifacts and to orchestrate Rust static libs.

High‑level targets:
- Core: `zig build` (default)
- Unit tests: `zig build -Doptimize=Debug test`
- Integration test exe: `zig build inttest` (run `zig-out/bin/aifw_core_test`)

Environment variables during JS model preparation (used by `tests/transformer-js` tools):
- `ALLOW_REMOTE=1` enables online model downloads
- `HF_TOKEN`, `HF_ENDPOINT` for Hugging Face
- `HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY` for proxies

Examples:
```bash
zig build
zig build -Doptimize=Debug test
zig build inttest && zig-out/bin/aifw_core_test
```

Artifacts are installed under `zig-out/`.

### Debug symbols and stack traces

Debug builds keep symbols so crashes can show stack traces:

```bash
zig build -Doptimize=Debug
```

Release builds strip symbols by default.

### Unit tests (Zig)

Run Zig unit tests defined in `core/aifw_core.zig`:

```bash
zig build -Doptimize=Debug test
```

Example output:

```text
masked=Contact me: __PII_EMAIL_ADDRESS_00000001__ and visit __PII_URL_ADDRESS_00000002__
restored=Contact me: a.b+1@test.io and visit https://ziglang.org
```

### Integration test executable

An integration test is provided at `tests/test-aifw-core/test_session.zig` and built as a standalone executable:

```bash
# Build and run the integration test
zig build inttest

# Or run the installed binary directly after build
zig-out/bin/aifw_core_test
```

This test exercises the full mask/restore pipeline, including the Rust regex recognizers.


## The design of Zig aifw core library

The aifw core library is implemented in Zig with two build targets: native and `wasm32-freestanding`. It integrates a Rust‑based regex engine (using `regex-automata`) compiled to static libraries (`.a`) for both native and WASM, then linked into the Zig library.

Highlights:
- Pipeline architecture with two pipelines: `mask` and `restore`.
- Sessions hold configured components and allocators; pipelines are pure and side‑effect‑free.
- PII detection is produced by a composite of:
      RegexRecognizer (Rust regex via C ABI),
      NerRecognizer (external NER → spans),
      SpanMerger (merge, filter, and de‑duplicate spans)
- Rust regex is implemented with `regex-automata` and exposed via a C ABI static library; it is built for native and WASM targets and linked into the Zig core.
- Masking replaces sensitive spans with placeholders like `__PII_EMAIL_ADDRESS_00000001__` and records minimal metadata; restoring reconstructs the original text using that metadata.
- Placeholders are generated using a stack buffer (no heap); metadata stores only `(EntityType, serial_id)` to minimize memory and avoid pointer issues.
- Built and tested with Zig 0.15.1; Rust static libs are produced for native and `wasm32-unknown-unknown`.


## LLM API key JSON format (OpenAI-compatible)

Example:
```json
{
  "openai-api-key": "xxxxxxxx.xxxx",
  "openai-base-url": "https://api.openai.com/v1",
  "openai-model": "gpt-4o-mini"
}
```

- openai-api-key: Your LLM API key string used for authentication.
- openai-base-url: Base URL of an OpenAI-compatible endpoint (e.g., OpenAI, a gateway, or a vendor’s OpenAI-style API).
- openai-model: Default model identifier for requests (can be overridden internally as needed).

Note: Keys using underscores are also accepted (e.g., `openai_api_key`, `openai_base_url`, `openai_model`).

## JavaScript projects

This repo uses a pnpm workspace (see `pnpm-workspace.yaml`) to manage all JS projects. Always install dependencies from the repo root:

```bash
pnpm -w install
```

### Build aifw-js library:`@oneaifw/aifw-js`

The library bundles Transformers.js, copies ORT/AIFW WASM files, and stages configured NER models.

Requirements:
- Build the core first (`zig build`) so `zig-out/bin/liboneaifw_core.wasm` exists
- Prepare model files under `ner-models/` or set `AIFW_MODELS_DIR`

Build:

```bash
# From repo root
pnpm -w --filter @oneaifw/aifw-js build
```

Environment variables affecting model copy (see `libs/aifw-js/scripts/copy-assets.mjs`):
- `AIFW_MODELS_DIR` (defaults to `ner-models/`)
- `AIFW_MODEL_IDS` comma‑separated model IDs (default: `funstory-ai/neurobert-mini`)
The user must correctly set these two variables to build oneaifw/aifw-js project.

Model preparation (optional helpers):
- `tests/transformer-js/scripts/prep-models.mjs` downloads and organizes models for browser usage
  - Online: `ALLOW_REMOTE=1 node tests/transformer-js/scripts/prep-models.mjs`
  - Honor `HF_TOKEN`, proxy vars as needed

### Run the web demo (`apps/webapp`)

```bash
pnpm -w --filter @oneaifw/aifw-js build
cd apps/webapp
pnpm dev
```

Offline build (copies library dist and produces `aifw-offline.html`):

```bash
cd apps/webapp
pnpm offline
```

Serve with cross‑origin isolation helper (if needed for WASM threading):

```bash
pnpm run serve:coi
# open the printed URL
```

### Browser extension (`browser_extension`)

See `browser_extension/README.md` for packaging and loading into Chrome/Edge. In short:

```bash
pnpm -w --filter @oneaifw/aifw-js build
mkdir -p browser_extension/vendor/aifw-js
rsync -a --exclude 'models' libs/aifw-js/dist/* browser_extension/vendor/aifw-js
# then load the folder as an unpacked extension
```

## Python backend (`py-origin`)

The backend service and CLI are in `py-origin/`. It provides HTTP APIs:
- `/api/call`, `/api/mask_text`, `/api/restore_text`, `/api/mask_text_batch`, `/api/restore_text_batch`

Authentication:
- Standard `Authorization` header; configure the key with env `AIFW_HTTP_API_KEY` or CLI option

Start here: `py-origin/README.md`.

## Docker

Build profiles for spaCy models via `--build-arg SPACY_PROFILE=...`:

- minimal (default): en_core_web_sm, zh_core_web_sm, xx_ent_wiki_sm
- fr: minimal + fr_core_news_sm
- de: minimal + de_core_news_sm
- ja: minimal + ja_core_news_sm
- multi: minimal + fr/de/ja

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

### Set api_key_file for Docker

You can provide the LLM API key file to the container via an environment variable and a bind mount. Two options:

- Put your key file inside your host work dir (`~/.aifw`) and mount the directory:
```bash
# Ensure the key file is at ~/.aifw/your-key.json on host
docker run --rm -p 8844:8844 \
  -e AIFW_API_KEY_FILE=/data/aifw/your-key.json \
  -v $HOME/.aifw:/data/aifw \
  oneaifw:latest
```

- Or mount the key file directly to a path inside the container and point AIFW_API_KEY_FILE to it:
```bash
docker run --rm -p 8844:8844 \
  -e AIFW_API_KEY_FILE=/data/aifw/your-key.json \
  -v /path/to/api-keys/your-key.json:/data/aifw/your-key.json \
  oneaifw:latest
```

### Using the Docker image to run aifw commands

Since the Docker image’s default command already launches the HTTP server, you don’t need to run `aifw launch` manually. You can still execute other commands inside the running container:

1) Run the OneAIFW docker image in interactive mode
```bash
docker run -it --name aifw \
  -p 8844:8844 \
  -e AIFW_API_KEY_FILE=/data/aifw/your-key.json \
  -v $HOME/.aifw:/data/aifw \
  oneaifw:latest \
  /bin/bash
```

2) Start the OneAIFW server
```bash
# Use the CLI interface of OneAIFW inside container
python -m aifw launch
```

3) Call the OneAIFW for translate text or do other things
```bash
# Use the CLI interface of OneAIFW inside container
python -m aifw call "请把如下文本翻译为中文: My email address is test@example.com, and my phone number is 18744325579."
```

4) Stop the OneAIFW server
```bash
# Use the CLI interface of OneAIFW inside container
python -m aifw stop
```

5) Exit the OneAIFW docker and Cleanup resources
```bash
exit
docker rm -f aifw
```
