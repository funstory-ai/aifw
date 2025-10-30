OneAIFW
===

OneAIFW is a local and lightweight firewall can protect users leak their privacy or secret when calling outside LLM API.

OneAIFW works like a transparent proxy between caller and callee.


## Getting Started
OneAIFW lets you safely call external LLM providers by anonymizing sensitive data first, then restoring it after the model response. You can run it as a local HTTP service or use an in‑process CLI. Follow the steps below to get up and running quickly.

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
If you want HTTP server API has a authorization, you should set environment variable
AIFW_HTTP_API_KEY with bash command:
```bash
# The 8H234B can be replaced by your key
export AIFW_HTTP_API_KEY=8H234B
```

The default output of logger is file
```bash
cd py-origin
python -m aifw launch
```
You should see output like:
```
aifw is running at http://localhost:8844.
logs: ~/.aifw/aifw_server-2025-08.log
```

### Call the HTTP service
```bash
cd py-origin
python -m aifw call "请把如下文本翻译为中文: My email address is test@example.com, and my phone number is 18744325579."
```

You can override the LLM API key file per call using `--api-key-file`:
```bash
cd py-origin
python -m aifw call --api-key-file /path/to/api-keys/your-key.json "..."
```

### Stop the server
```bash
cd py-origin
python -m aifw stop
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

## zig build

We use Zig's build system as the single entrypoint to orchestrate the whole project: the Zig core library, Rust regex static libs, the browser JS app under `tests/transformer-js`, and the Python apps under `py-origin`. This gives us a reproducible, cross‑platform build with one command.

Feasibility: Zig's build runner can invoke arbitrary system commands (Cargo, Node/NPM, Python, etc.) via process steps, manage dependencies between them, and expose convenient targets. This pattern is already used in this repo to build the Rust regex libraries for both native and WASM. Extending it to JS and Python is straightforward and recommended.

High‑level targets (conceptual):
- Core: `zig build` builds Zig static libs and Rust `.a` (native + WASM)
- Tests: `zig build test` (unit), `zig build inttest` (integration executable)
- Web app: `zig build web` prepares models and builds `tests/transformer-js` with Vite
- Web dev server: `zig build web-dev` runs Vite dev (long‑running)
- Python: `zig build py-setup` prepares venv; `zig build py-wheel` builds a wheel; `zig build py-run` runs the app or service

Notes:
- The current `build.zig` already wires the core library, Rust regex (native/WASM), and tests. Adding `web`, `web-dev`, and Python targets is done by adding system command steps (NPM/Cargo/Python) and wiring dependencies.
- Outputs can be:
  - JS web app bundle (for standalone demo, or copied into a browser extension/package)
  - Python wheel or runnable entrypoints (CLI and service)

Environment variables honored during JS model preparation (when `zig build web` runs `tests/transformer-js/scripts/prep-models.mjs`):
- `ALLOW_REMOTE=1` enables online model downloads
- `HF_TOKEN`, `HF_ENDPOINT` provide Hugging Face auth/mirror
- `HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY` control network proxying

Example end‑to‑end flows (once the targets are added):
```bash
# Build everything (core + regex + planned web bundle)
zig build

# Unit tests for core
zig build -Doptimize=Debug test

# Integration test executable
zig build inttest && zig-out/bin/aifw_core_test

# Build the web demo (downloads/converts models, then vite build)
ALLOW_REMOTE=1 HF_TOKEN=... zig build web

# Prepare Python venv and build a wheel
zig build py-setup
zig build py-wheel
```


## Zig core library

The core library is implemented in Zig with two build targets: native and `wasm32-freestanding`. It integrates a Rust‑based regex engine (using `regex-automata`) compiled to static libraries (`.a`) for both native and WASM, then linked into the Zig library.

Highlights:
- Pipeline architecture with two pipelines: `mask` and `restore`
- Session holds configured components and allocators; pipelines are pure and side‑effect free
- RegexRecognizer (Rust regex via C ABI), NerRecognizer (external NER → spans), SpanMerger (merge/filter/dedup spans)
- Placeholders are dynamically generated like `__PII_EMAIL_ADDRESS_00000001__`, but produced using a stack buffer (no heap) and metadata stores only `(EntityType, serial)` to avoid dangling pointers and minimize memory
- Restore reconstructs placeholders on the fly and replaces them with the original spans in order
- Built and tested with Zig 0.15.1; Rust static libs are produced for native and `wasm32-unknown-unknown`

### Prerequisites

- Zig 0.15.1 (required)
- Rust toolchain (stable) with Cargo
  - Add WASM target: `rustup target add wasm32-unknown-unknown`

Verify versions:

```bash
zig version        # should print 0.15.1
rustc --version
cargo --version
```

### Build (native + WASM)

The build orchestrates Rust static libraries and Zig artifacts automatically:

```bash
# From repository root
zig build
```

What happens:
- Builds Rust regex C-ABI static libs:
  - Native: `libs/regex/target/release/libaifw_regex.a`
  - WASM: `libs/regex/target/wasm32-unknown-unknown/release/libaifw_regex.a`
- Builds Zig static libraries:
  - Native: `oneaifw_core` (.a)
  - WASM (freestanding): `oneaifw_core_wasm` (.a)

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

### Notes on the core design

- The `Pipeline` has `mask` and `restore` modes. Masking replaces sensitive spans with placeholders like `__PII_EMAIL_ADDRESS_00000001__` and records metadata; restoring reconstructs the original text using that metadata.
- Placeholders are generated without heap allocations using a stack buffer; metadata stores only `(EntityType, serial)` to minimize memory and avoid pointer invalidation.
- Rust regex is implemented with `regex-automata` and exposed via a C ABI static library; it is built for native and WASM targets and linked into the Zig core.

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
