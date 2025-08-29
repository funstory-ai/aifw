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
python -m venv .venv
source .venv/bin/activate  # Windows: .venv\\Scripts\\activate
```

### Install dependencies
```bash
pip install -r services/requirements.txt
pip install -r cli/requirements.txt
python -m spacy download en_core_web_sm
python -m spacy download zh_core_web_sm
python -m spacy download xx_ent_wiki_sm
```

### Prepare config and API key file
The default aifw.yaml is in assets directory, you can modify this file for yourself.

```bash
mkdir -p ~/.aifw
cp assets/aifw.yaml ~/.aifw/aifw.yaml
# edit ~/.aifw/aifw.yaml and set api_key_file to your key JSON
```

### Launch HTTP server
The default output of logger is file
```bash
python -m aifw launch
```
You should see output like:
```
aifw is running at http://localhost:8844.
logs: ~/.aifw/aifw_server-2025-08.log
```

### Call the HTTP service
```bash
python -m aifw call "请把如下文本翻译为中文: My email address is test@example.com, and my phone number is 18744325579."
```

You can override the API key file per call using `--api-key-file`:
```bash
python -m aifw call --api-key-file /path/to/api-keys/your-key.json "..."
```

### Stop the server
```bash
python -m aifw stop
```

### Direct in-process call (no HTTP)
```bash
python -m aifw direct_call "请把如下文本翻译为中文: My email address is test@example.com, and my phone number is 18744325579."
```

You can also switch provider dynamically per call:
```bash
python -m aifw direct_call --api-key-file /path/to/api-keys/your-key.json "..."
```

### Parameter precedence

For all configurable parameters, the resolution order is:

1. Command-line arguments
2. Environment variables
3. Config file (`aifw.yaml`)

For example, the API key file is resolved as:

- CLI: `--api-key-file`
- Env: `AIFW_API_KEY_FILE`
- Config: `api_key_file` in `aifw.yaml`

The same precedence applies to port, logging options, etc.

## API key JSON format (OpenAI-compatible)

Example:
```json
{
  "openai-api-key": "xxxxxxxx.xxxx",
  "openai-base-url": "https://api.openai.com/v1",
  "openai-model": "gpt-4o-mini"
}
```

- openai-api-key: Your API key string used for authentication.
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

You can provide the API key file to the container via an environment variable and a bind mount. Two options:

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