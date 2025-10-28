from typing import Optional, Dict, Any, List
import json

from .analyzer import AnalyzerWrapper, EntitySpan
from .anonymizer import AnonymizerWrapper
from .llm_client import LLMClient, load_llm_api_config


class OneAIFWAPI:
    """Unified in-process API for anonymize→LLM→restore flows.

    Intended to be used by local callers (UI/CLI) and wrapped by HTTP server.
    Only exposes the generic `call` method; analysis/anonymize/restore are internal.
    """

    def __init__(self):
        self._analyzer_wrapper = AnalyzerWrapper()
        self._anonymizer_wrapper = AnonymizerWrapper(self._analyzer_wrapper)
        self._llm = LLMClient()

    # Internal helpers (not for external exposure)
    def _analyze(self, text: str, language: str = "en") -> List[EntitySpan]:
        return self._analyzer_wrapper.analyze(text=text, language=language)

    def _anonymize(
        self,
        text: str,
        operators: Optional[Dict[str, Dict[str, Any]]] = None,
        language: str = "en",
    ) -> Dict[str, Any]:
        return self._anonymizer_wrapper.anonymize(
            text=text, operators=operators, language=language
        )

    def _restore(self, text: str, placeholders_map: Dict[str, str]) -> str:
        return self._anonymizer_wrapper.restore(text=text, placeholders_map=placeholders_map)

    # Public API
    def mask_text(self, text: str, language: Optional[str] = None) -> Dict[str, Any]:
        """Mask PII in text and return masked text plus metadata for restoration.

        Mirrors the behavior expected by frontends using mask/restore flows.
        """
        lang = language or self._analyzer_wrapper.detect_language(text)
        anon = self._anonymizer_wrapper.anonymize(text=text, operators=None, language=lang)
        # Serialize placeholdersMap (dict) into UTF-8 JSON bytes, then expose as bytes array (list[int])
        serialized = json.dumps(anon["placeholdersMap"], ensure_ascii=False).encode("utf-8")
        return {"text": anon["text"], "maskMeta": serialized}

    def restore_text(self, text: str, mask_meta: bytes) -> str:
        """Restore masked placeholders to their original values using mask metadata.

        Accepts mask_meta as bytes; decodes JSON → dict.
        """
        placeholders_map = json.loads(mask_meta.decode("utf-8"))
        return self._anonymizer_wrapper.restore(text=text, placeholders_map=placeholders_map)

    def call(
        self,
        text: str,
        api_key_file: Optional[str] = None,
        model: Optional[str] = None,
        temperature: float = 0.0,
    ) -> str:
        language = self._analyzer_wrapper.detect_language(text)

        # 1) anonymize input
        anon = self._anonymizer_wrapper.anonymize(text=text, operators=None, language=language)
        anonymized_text = anon["text"]
        placeholders = anon["placeholdersMap"]

        # 2) load LLM config if provided
        cfg = {"model": None}
        if api_key_file:
            cfg = load_llm_api_config(api_key_file)

        # 3) LLM call (no source language hint; use anonymized text as-is)
        output = self._llm.call(
            text=anonymized_text,
            model=model or cfg.get("model") or None,
            temperature=temperature,
        )

        # 4) restore placeholders back to original values
        restored = self._anonymizer_wrapper.restore(text=output, placeholders_map=placeholders)
        return restored


# Singleton and module-level function for convenience
api = OneAIFWAPI()


def call(
    text: str,
    api_key_file: Optional[str] = None,
    model: Optional[str] = None,
    temperature: float = 0.0,
) -> str:
    return api.call(
        text=text,
        api_key_file=api_key_file,
        model=model,
        temperature=temperature,
    )


def mask_text(text: str, language: Optional[str] = None) -> Dict[str, Any]:
    return api.mask_text(text=text, language=language)


def restore_text(text: str, mask_meta: Any) -> str:
    return api.restore_text(text=text, mask_meta=mask_meta)


