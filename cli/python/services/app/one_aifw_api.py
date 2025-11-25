from typing import Optional, Dict, Any, List
import json
import base64
import os
import sys
import importlib
import importlib.util

from .llm_client import LLMClient, load_llm_api_config


def _load_aifw_py():
    """
    Load libs/aifw-py as package 'aifw_py' so that we can import aifw_py.libaifw.
    """
    # repo_root/cli/python/services/app/one_aifw_api.py -> go up 4 levels to repo root
    repo_root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "..", ".."))
    pkg_dir = os.path.join(repo_root, "libs", "aifw-py")
    init_py = os.path.join(pkg_dir, "__init__.py")
    if not os.path.exists(init_py):
        raise RuntimeError("aifw-py package not found at: %s" % pkg_dir)
    if "aifw_py" not in sys.modules:
        spec = importlib.util.spec_from_file_location(
            "aifw_py",
            init_py,
            submodule_search_locations=[pkg_dir],
        )
        mod = importlib.util.module_from_spec(spec)
        sys.modules["aifw_py"] = mod
        loader = spec.loader
        assert loader is not None
        loader.exec_module(mod)
    return importlib.import_module("aifw_py.libaifw")


class OneAIFWAPI:
    """Unified in-process API for anonymize→LLM→restore flows.

    Intended to be used by local callers (UI/CLI) and wrapped by HTTP server.
    The exposed API function is list in below:
    - mask_text: mask a piece of text and return masked text plus metadata for restoration.
    - restore_text: restore the masked text plus matching metadata, return a restored text.
    # - mask_text_batch: mask a batch of texts and return batch of masked texts plus matching metadatas for restoration.
    # - restore_text_batch: restore a batch of masked texts and matching metadatas, return a restored text.
    - call: mask a piece of text, process the masked text (e.g., translation), and then restore it.
    """

    def __init__(self):
        self._llm = LLMClient()
        # Lazy-load aifw-py core
        self._aifw = _load_aifw_py()
        self._aifw.init()

    def __del__(self):
        self._aifw.deinit()
        self._aifw = None
        self._llm = None

    # Public API
    def mask_text(self, text: str, language: Optional[str] = None) -> Dict[str, Any]:
        """Mask PII in text and return masked text plus metadata for restoration.

        maskMeta is a base64 string of binary maskMeta bytes produced by aifw core.
        """
        # Let aifw-py handle language auto-detection if language is None or "auto"
        lang = None if (language is None or language == "" or language == "auto") else language
        masked_text, meta_bytes = self._aifw.mask_text(text, lang)
        mask_meta_b64 = base64.b64encode(meta_bytes).decode("ascii")
        return {"text": masked_text, "maskMeta": mask_meta_b64}

    def restore_text(self, text: str, mask_meta: Any) -> str:
        """Restore masked text using base64-encoded binary maskMeta produced by aifw core."""
        try:
            if isinstance(mask_meta, (bytes, bytearray)):
                meta_bytes = bytes(mask_meta)
            else:
                meta_bytes = base64.b64decode(str(mask_meta), validate=False)
        except Exception:
            meta_bytes = b""
        return self._aifw.restore_text(text, meta_bytes)

    def config(self, mask_config: Dict[str, Any]) -> None:
        """
        Configure AIFW core session (e.g. which entity types are masked).

        This delegates to aifw_py.libaifw.config, which calls aifw_session_config()
        in the Zig core. The mask_config schema mirrors the JS maskConfig:
        {
          "maskAddress": bool,
          "maskEmail": bool,
          "maskOrganization": bool,
          "maskUserName": bool,
          "maskPhoneNumber": bool,
          "maskBankNumber": bool,
          "maskPayment": bool,
          "maskVerificationCode": bool,
          "maskPassword": bool,
          "maskRandomSeed": bool,
          "maskPrivateKey": bool,
          "maskUrl": bool,
          "maskAll": bool
        }
        """
        if not isinstance(mask_config, dict):
            return
        try:
            if hasattr(self._aifw, "config"):
                self._aifw.config(mask_config)  # type: ignore[attr-defined]
        except Exception:
            # Configuration errors should not crash callers; keep previous config.
            return

    def get_pii_entities(self, text: str, language: Optional[str] = None) -> List[Dict[str, Any]]:
        """
        Analyze text and return PII spans using aifw core get_pii_spans().
        Returns a list of dicts with {entity_id, entity_type, start, end, text}.
        """
        lang = None if (language is None or language == "" or language == "auto") else language
        spans = self._aifw.get_pii_spans(text, lang)

        # matched_start / matched_end from core are UTF-8 byte offsets.
        # Build a map from byte offset -> character index so that frontend
        # can safely slice Python strings with character-based indices.
        utf8 = text.encode("utf-8")
        n_bytes = len(utf8)
        byte_to_char: List[int] = [0] * (n_bytes + 1)
        byte_pos = 0
        for char_index, ch in enumerate(text):
            byte_to_char[byte_pos] = char_index
            byte_pos += len(ch.encode("utf-8"))
        # Ensure the terminal position maps to len(text)
        if byte_pos == n_bytes:
            byte_to_char[n_bytes] = len(text)
        else:
            byte_to_char[-1] = len(text)

        def _byte_off_to_char(off: int) -> int:
            if off <= 0:
                return 0
            if off >= len(byte_to_char):
                return len(text)
            # If offset does not land exactly on a recorded boundary,
            # clamp to the nearest previous character boundary.
            idx = off
            while idx > 0 and byte_to_char[idx] == 0:
                idx -= 1
            return byte_to_char[idx]

        results: List[Dict[str, Any]] = []
        for s in spans:
            b_start = int(getattr(s, "matched_start", 0))
            b_end = int(getattr(s, "matched_end", 0))
            start = _byte_off_to_char(b_start)
            end = _byte_off_to_char(b_end)
            frag = text[start:end]
            results.append(
                {
                    "entity_id": int(getattr(s, "entity_id", 0)),
                    "entity_type": int(getattr(s, "entity_type", 0)),
                    "start": start,
                    "end": end,
                    "text": frag,
                }
            )
        return results

    # def mask_text_batch(self, texts: List[str], language: Optional[str] = None) -> List[Dict[str, Any]]:
    #     """Mask a batch of texts and return batch of masked texts plus matching metadatas for restoration."""
    #     return [self.mask_text(text=text, language=language) for text in texts]

    # def restore_text_batch(self, texts: List[str], mask_metas: List[Any]) -> str:
    #     """Restore a batch of masked texts and matching metadatas, return a restored text."""
    #     return [self.restore_text(text=text, mask_meta=mask_meta) for text, mask_meta in zip(texts, mask_metas)]

    def call(
        self,
        text: str,
        api_key_file: Optional[str] = None,
        model: Optional[str] = None,
        temperature: float = 0.0,
    ) -> str:
        language = self._aifw.detect_language(text)

        # 1) anonymize input
        anonymized_text, meta_bytes = self._aifw.mask_text(input_text=text, language=language)

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

        # 4) restore masked text plus matching metadata, return a restored text.
        restored = self._aifw.restore_text(masked_text=output, mask_meta=meta_bytes)
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


def config(mask_config: Dict[str, Any]) -> None:
    api.config(mask_config)


