from typing import Optional

from .one_aifw_api import OneAIFWAPI


class OneAIFWLocalAPI(OneAIFWAPI):
    """Local in-process API used by CLI/UI. Wraps OneAIFWAPI."""
    pass


# Singleton instance to be shared across imports
api = OneAIFWLocalAPI()


def call(
        text: str,
        api_key_file: Optional[str] = None,
        model: Optional[str] = None,
        temperature: float = 0.0,
        language: str = "en",
        ) -> str:
    return api.call(
            text=text,
            api_key_file=api_key_file,
            model=model,
            temperature=temperature,
            language=language,
            )
