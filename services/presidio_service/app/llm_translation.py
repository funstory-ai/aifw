from typing import Optional, Dict, Any
import os
import json
import importlib


class Translator:
    """LLM-based translator using LiteLLM.

    Requires provider API key(s) via environment variables as per LiteLLM docs
    (e.g., OPENAI_API_KEY for OpenAI models). The `model` parameter selects the
    provider/model, e.g., "gpt-4o-mini", "openrouter/anthropic/claude-3.5-sonnet",
    etc.
    """

    def __init__(self, default_model: str = "gpt-4o-mini"):
        self.default_model = default_model

    def translate(
        self,
        text: str,
        target_language: str,
        source_language: Optional[str] = None,
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

        # Put all instructions in the system message so the user-provided text remains unchanged
        # if source_language:
        #     sys_prompt = (
        #         f"You are a professional translation engine. Translate the user's next message "
        #         f"from {source_language} to {target_language}. Do not add explanations. "
        #         f"Preserve any tokens that look like placeholders (e.g., __PII_...__)."
        #     )
        # else:
        #     sys_prompt = (
        #         f"You are a professional translation engine. Translate the user's next message "
        #         f"to {target_language}. Do not add explanations. "
        #         f"Preserve any tokens that look like placeholders (e.g., __PII_...__)."
        #     )
        prefix_prompt = f"Translate the following text to {target_language}: "
        user_prompt = prefix_prompt + text


        # Ensure OpenAI-compatible provider path for custom api_base endpoints (e.g., ZhipuAI OpenAI-compatible)
        provider_kwargs = {
            "custom_llm_provider": "openai",
        }
        api_base = os.environ.get("OPENAI_API_BASE")
        api_key = os.environ.get("OPENAI_API_KEY")
        if api_base:
            provider_kwargs["api_base"] = api_base
        if api_key:
            provider_kwargs["api_key"] = api_key

        resp = litellm.completion(
            model=chosen_model,
            messages=[
                #{"role": "system", "content": sys_prompt},
                {"role": "user", "content": user_prompt},
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

    Expected fields (hyphen or underscore both supported):
      - openai-api-key / openai_api_key
      - openai-model   / openai_model
      - openai-base-url / openai_base_url (OpenAI-compatible base URL)

    Effects:
      - Sets OPENAI_API_KEY and OPENAI_API_BASE environment variables for LiteLLM
      - Returns a dict containing { 'model': <model or None> }
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

    if api_key:
        os.environ['OPENAI_API_KEY'] = api_key
    else:
        raise ValueError("openai-api-key not found in config file")

    if base_url:
        # LiteLLM respects OPENAI_API_BASE for OpenAI-compatible endpoints
        os.environ['OPENAI_API_BASE'] = base_url

    return {'model': model}


