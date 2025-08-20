from typing import Optional, Dict, Any
import os
import json
import importlib


class LLMClient:
    """LiteLLM-based generic LLM caller.

    Requires provider API key(s) via environment variables as per LiteLLM docs.
    The `model` parameter selects the provider/model (e.g., "gpt-4o-mini", "glm-4").
    For OpenAI-compatible gateways (e.g., Zhipu), configure OPENAI_API_KEY + OPENAI_API_BASE.
    """

    def __init__(self, default_model: str = "gpt-4o-mini"):
        self.default_model = default_model

    def call(
        self,
        text: str,
        model: Optional[str] = None,
        temperature: float = 0.0,
    ) -> str:
        # Lazy import litellm here to surface precise import errors inside the active venv
        try:
            litellm = importlib.import_module("litellm")
        except Exception as exc:
            raise RuntimeError(
                f"Failed to import litellm. Please ensure it is installed in the current environment: {exc}"
            )

        chosen_model = model or self.default_model
        # Normalize common GLM naming to OpenAI-compatible model id
        if isinstance(chosen_model, str) and "/" in chosen_model:
            # e.g., "zhipuai/glm-4" -> "glm-4"
            provider_prefix, maybe_model = chosen_model.split("/", 1)
            if provider_prefix.lower() in {"zhipuai", "glm", "openai"} and maybe_model:
                chosen_model = maybe_model

        provider_kwargs = {"custom_llm_provider": "openai"}
        api_base = os.environ.get("OPENAI_API_BASE")
        api_key = os.environ.get("OPENAI_API_KEY")
        if api_base:
            provider_kwargs["api_base"] = api_base
        if api_key:
            provider_kwargs["api_key"] = api_key

        resp = litellm.completion(
            model=chosen_model,
            messages=[
                {"role": "user", "content": text},
            ],
            temperature=temperature,
            **provider_kwargs,
        )
        content = (
            resp.choices[0].message.get("content")
            if hasattr(resp.choices[0], "message")
            else resp.choices[0].get("message", {}).get("content")
        )
        return content or ""


def load_llm_api_config(file_path: str) -> Dict[str, Any]:
    """Load LLM config for LiteLLM from a JSON file.

    Supported keys (hyphen or underscore are both accepted):
      - openai-api-key / openai_api_key
      - openai-model   / openai_model
      - openai-base-url / openai_base_url (OpenAI-compatible base URL)

    Side effects:
      - Sets OPENAI_API_KEY and OPENAI_API_BASE
      - Returns dict { 'model': <model or None> }
    """
    with open(file_path, 'r', encoding='utf-8') as f:
        data = json.load(f)

    def get_any(*keys):
        for k in keys:
            if k in data and data[k]:
                return data[k]
        return None

    api_key = get_any('openai-api-key', 'openai_api_key')
    model = get_any('openai-model', 'openai_model')
    base_url = get_any('openai-base-url', 'openai_base_url')

    if not api_key:
        raise ValueError("openai-api-key not found in config file")
    os.environ['OPENAI_API_KEY'] = api_key
    if base_url:
        os.environ['OPENAI_API_BASE'] = base_url

    return {'model': model}


