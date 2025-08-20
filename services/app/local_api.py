from typing import Dict, Any, Optional, List

from .analyzer import AnalyzerWrapper, EntitySpan
from .anonymizer import AnonymizerWrapper
from .llm_translation import Translator, load_llm_api_config


class OneAIFWLocalAPI:
    """In-process local API for anonymization and restoration.

    This avoids HTTP and can be imported by UI/CLI directly.
    Heavy Presidio engines are initialized once and reused.
    """

    def __init__(self):
        self._analyzer_wrapper = AnalyzerWrapper()
        self._anonymizer_wrapper = AnonymizerWrapper(self._analyzer_wrapper.engine)
        self._translator = Translator()

    def analyze(self, text: str, language: str = "en") -> List[EntitySpan]:
        return self._analyzer_wrapper.analyze(text=text, language=language)

    def anonymize(
        self,
        text: str,
        operators: Optional[Dict[str, Dict[str, Any]]] = None,
        language: str = "en",
    ) -> Dict[str, Any]:
        return self._anonymizer_wrapper.anonymize(
            text=text, operators=operators, language=language
        )

    def restore(self, text: str, placeholders_map: Dict[str, str]) -> str:
        return self._anonymizer_wrapper.restore(text=text, placeholders_map=placeholders_map)

    def translate(
        self,
        text: str,
        target_language: str,
        api_key_file: Optional[str] = None,
        model: Optional[str] = None,
        temperature: float = 0.0,
        language: str = "en",
    ) -> str:
        # 1) anonymize
        anon = self._anonymizer_wrapper.anonymize(text=text, operators=None, language=language)
        anonymized_text = anon["text"]
        placeholders = anon["placeholdersMap"]

        # 2) load LLM config if provided
        if api_key_file:
            cfg = load_llm_api_config(api_key_file)
        else:
            cfg = {"model": None}

        # 3) translate (LLM auto-detects source language). Keep user message unmodified.
        translated = self._translator.translate(
            text=anonymized_text,
            target_language=target_language,
            source_language=None,
            model=model or cfg.get('model') or None,
            temperature=temperature,
        )

        # 4) restore
        restored = self._anonymizer_wrapper.restore(text=translated, placeholders_map=placeholders)
        return restored


# Singleton instance to be shared across imports
api = OneAIFWLocalAPI()


# Convenience module-level functions
def analyze(text: str, language: str = "en") -> List[EntitySpan]:
    return api.analyze(text=text, language=language)


def anonymize(
    text: str,
    operators: Optional[Dict[str, Dict[str, Any]]] = None,
    language: str = "en",
) -> Dict[str, Any]:
    return api.anonymize(text=text, operators=operators, language=language)


def restore(text: str, placeholders_map: Dict[str, str]) -> str:
    return api.restore(text=text, placeholders_map=placeholders_map)


def translate(
    text: str,
    target_language: str,
    api_key_file: Optional[str] = None,
    model: Optional[str] = None,
    temperature: float = 0.0,
    language: str = "en",
) -> str:
    return api.translate(
        text=text,
        target_language=target_language,
        api_key_file=api_key_file,
        model=model,
        temperature=temperature,
        language=language,
    )


def translate_with_presidio_and_glm(
    text: str,
    api_key_file: str,
    model: str = "zhipuai/glm-4",
    prompt_prefix: str = "请将这段英文内容翻译为中文：",
    language: str = "en",
) -> str:
    return api.translate_with_presidio_and_glm(
        text=text,
        api_key_file=api_key_file,
        model=model,
        prompt_prefix=prompt_prefix,
        language=language,
    )


