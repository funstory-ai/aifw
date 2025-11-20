"""
High-level AIFW API for Python.

This module mirrors aifw-js/libaifw.js in surface API:
- init(options)
- deinit()
- detect_language(text) -> { lang, script, confidence, method }
- mask_text(text, language) -> (masked_text, mask_meta: bytes)
- restore_text(masked_text, mask_meta) -> text
- mask_text_batch(items) -> [{ text, maskMeta }]
- restore_text_batch(items) -> [{ text }]
- get_pii_spans(text, language) -> List[MatchedPIISpan]

Implementation notes:
- Uses Presidio-based analyzer/anonymizer from py-origin for NER and masking.
- mask_meta is a UTF-8 JSON-serialized object for reversible restore:
  { "placeholdersMap": { "__PII_...__": "original" }, "language": "en" }
"""
from __future__ import annotations

import json
import logging
from dataclasses import dataclass
from typing import Any, Dict, List, Optional, Tuple, Union

from .libner import init_env as ner_init_env, build_ner_pipeline
from ...py-origin.services.app.analyzer import AnalyzerWrapper
from ...py-origin.services.app.anonymizer import AnonymizerWrapper

logger = logging.getLogger(__name__)


# Global state
_ANALYZER: Optional[AnalyzerWrapper] = None
_ANON: Optional[AnonymizerWrapper] = None
_NER_EN = None
_NER_ZH = None
_SESSION_OPEN = False


# Language/script detection helpers (heuristics + optional OpenCC)
_SIMPLIFIED_ONLY = set([
    "后", "发", "台", "里", "复", "面", "余", "划", "钟", "观", "厂", "广", "圆", "国", "东", "乐", "云", "内", "两",
    "丢", "为", "价", "众", "优", "冲", "况", "刘", "师", "于", "亏", "仅", "从", "兴", "举", "义", "乌", "专",
])
_TRADITIONAL_ONLY = set([
    "後", "發", "臺", "裡", "複", "麵", "餘", "劃", "鐘", "觀", "廠", "廣", "圓", "國", "東", "樂", "雲", "內", "兩",
    "丟", "為", "價", "眾", "優", "衝", "況", "劉", "師", "於", "虧", "僅", "從", "興", "舉", "義", "烏", "專",
])
_SIMPLIFIED_WORDS = ["开发", "软件", "后端", "互联网", "应用", "运维", "里程", "联系", "台阶", "复用"]
_TRADITIONAL_WORDS = ["開發", "軟體", "後端", "網際網路", "應用", "運維", "聯繫", "臺階", "複用"]


def _ratio_of_han(text: str) -> float:
    if not text:
        return 0.0
    total = 0
    han = 0
    for ch in text:
        total += 1
        if "\u4e00" <= ch <= "\u9fff" or "\u3400" <= ch <= "\u4dbf" or "\uf900" <= ch <= "\ufaff":
            han += 1
    return (han / total) if total else 0.0


def _ratio_of_latin(text: str) -> float:
    if not text:
        return 0.0
    total = 0
    lat = 0
    for ch in text:
        total += 1
        if ("A" <= ch <= "Z") or ("a" <= ch <= "z"):
            lat += 1
    return (lat / total) if total else 0.0


def _quick_lang(text: str) -> str:
    han = _ratio_of_han(text or "")
    lat = _ratio_of_latin(text or "")
    if han >= 0.3:
        return "zh"
    if lat >= 0.5:
        return "en"
    return "other"


def _score_by_sets(text: str) -> Tuple[int, int]:
    s_score = 0
    t_score = 0
    for ch in text:
        if ch in _SIMPLIFIED_ONLY:
            s_score += 1
        if ch in _TRADITIONAL_ONLY:
            t_score += 1
    for w in _SIMPLIFIED_WORDS:
        if w in text:
            s_score += 2
    for w in _TRADITIONAL_WORDS:
        if w in text:
            t_score += 2
    return s_score, t_score


def _quick_script_zh(text: str) -> Optional[str]:
    s_score, t_score = _score_by_sets(text or "")
    if s_score - t_score >= 2:
        return "Hans"
    if t_score - s_score >= 2:
        return "Hant"
    return None


def _decide_script_with_opencc(text: str) -> str:
    try:
        # Best-effort use of opencc; otherwise fallback to Hans
        try:
            from opencc import OpenCC  # type: ignore
            s2t = OpenCC("s2t")
            t2s = OpenCC("t2s")
            to_t = s2t.convert(text)
            to_s = t2s.convert(text)
            s_changed = (to_t != text)
            t_changed = (to_s != text)
            if s_changed and not t_changed:
                return "Hans"
            if not s_changed and t_changed:
                return "Hant"
        except Exception:
            pass
    except Exception:
        pass
    return "Hans"


async def detect_language(text: str) -> Dict[str, Any]:
    lang = _quick_lang(text or "")
    if lang != "zh":
        return {"lang": lang, "script": None, "confidence": 0.9 if lang == "en" else 0.6, "method": "heuristic"}
    script_quick = _quick_script_zh(text or "")
    if script_quick:
        return {"lang": "zh", "script": script_quick, "confidence": 0.8, "method": "heuristic"}
    script = _decide_script_with_opencc(text or "")
    return {"lang": "zh", "script": script, "confidence": 0.95, "method": "opencc"}


def init(options: Optional[Dict[str, Any]] = None) -> None:
    """
    Initialize aifw-py runtime.
    options are accepted for API parity; unknown keys are ignored.
    """
    global _ANALYZER, _ANON, _NER_EN, _NER_ZH, _SESSION_OPEN
    if _SESSION_OPEN:
        return
    options = options or {}
    # Initialize analyzer/anonymizer
    _ANALYZER = AnalyzerWrapper()
    _ANON = AnonymizerWrapper(_ANALYZER)
    # Initialize ner env and two pipelines (best-effort)
    ner_init_env({
        "wasmBase": (options.get("ort") or {}).get("wasmBase"),
        "modelsBase": (options.get("models") or {}).get("modelsBase"),
        "threads": (options.get("ort") or {}).get("threads"),
        "simd": (options.get("ort") or {}).get("simd"),
        "customCache": (options.get("models") or {}).get("customCache"),
    })
    # Model ids aligned with js defaults
    try:
        # Lazy async creation via event loop would complicate; call synchronously via simple wrappers
        import asyncio
        _NER_EN = asyncio.get_event_loop().run_until_complete(
            build_ner_pipeline("funstory-ai/neurobert-mini", {"quantized": True})
        )
        _NER_ZH = asyncio.get_event_loop().run_until_complete(
            build_ner_pipeline("ckiplab/bert-tiny-chinese-ner", {"quantized": True})
        )
    except Exception as e:
        logger.warning("Failed to prebuild NER pipelines: %s", e)
        _NER_EN = None
        _NER_ZH = None
    _SESSION_OPEN = True
    logger.info("[aifw-py] init complete.")


def deinit() -> None:
    """Tear down runtime."""
    global _ANALYZER, _ANON, _NER_EN, _NER_ZH, _SESSION_OPEN
    _ANALYZER = None
    _ANON = None
    _NER_EN = None
    _NER_ZH = None
    _SESSION_OPEN = False


def _select_language(input_text: str, language: Optional[str]) -> str:
    lang_to_use = language or ""
    if not lang_to_use or lang_to_use.lower() == "auto":
        # Use heuristic detector to pick major language bucket
        # Avoid async here for simplicity
        det = _quick_lang(input_text or "")
        if det == "zh":
            # Default to simplified for masking path unless strong Hant signal
            script = _quick_script_zh(input_text or "") or "Hans"
            return "zh-TW" if script == "Hant" else "zh-CN"
        return det or "en"
    return lang_to_use


def _entity_type_str_to_code(entity_type: str) -> int:
    """
    Map entity type string to enum code compatible with js core mapping.
    """
    et = (entity_type or "").upper()
    if et in ("PER", "PERSON", "USER_NAME"):
        return 4
    if et == "ORGANIZATION" or et == "ORG":
        return 3
    if et in ("LOC", "GPE", "FAC", "ADDRESS", "PHYSICAL_ADDRESS"):
        return 1
    if et == "EMAIL_ADDRESS":
        return 2
    if et == "PHONE_NUMBER":
        return 5
    if et == "BANK_NUMBER":
        return 6
    if et == "PAYMENT":
        return 7
    if et in ("VERIFY_CODE", "VERIFICATION_CODE"):
        return 8
    if et == "PASSWORD":
        return 9
    if et == "RANDOM_SEED":
        return 10
    if et == "PRIVATE_KEY":
        return 11
    if et in ("URL", "URL_ADDRESS"):
        return 12
    return 0


@dataclass
class MatchedPIISpan:
    entity_id: int
    entity_type: int
    matched_start: int
    matched_end: int


def _ensure_ready():
    if not _SESSION_OPEN or _ANALYZER is None or _ANON is None:
        raise RuntimeError("AIFW not initialized; call init() first")


def mask_text(input_text: str, language: Optional[str] = None) -> Tuple[str, bytes]:
    """
    Mask text and return tuple of (masked_text, mask_meta_bytes).
    mask_meta is JSON-serialized and consumable by restore_text.
    """
    _ensure_ready()
    lang_to_use = _select_language(input_text, language)
    result = _ANON.anonymize(text=str(input_text or ""), operators=None, language=lang_to_use.split("-")[0])
    masked = result.get("text", "")
    placeholders_map = result.get("placeholdersMap", {}) or {}
    meta = {"placeholdersMap": placeholders_map, "language": lang_to_use}
    meta_bytes = json.dumps(meta, ensure_ascii=False).encode("utf-8")
    return masked, meta_bytes


def restore_text(masked_text: str, mask_meta: Union[bytes, bytearray, memoryview, Dict[str, Any]]) -> str:
    """
    Restore text using mask_meta produced by mask_text.
    mask_meta can be bytes (JSON) or pre-parsed dict.
    """
    _ensure_ready()
    if isinstance(mask_meta, (bytes, bytearray, memoryview)):
        try:
            meta_obj = json.loads(bytes(mask_meta).decode("utf-8"))
        except Exception as e:
            raise ValueError(f"invalid mask_meta bytes: {e}")
    elif isinstance(mask_meta, dict):
        meta_obj = mask_meta
    else:
        raise ValueError("mask_meta must be bytes-like or dict")
    placeholders_map = meta_obj.get("placeholdersMap", {}) or {}
    return _ANON.restore(text=str(masked_text or ""), placeholders_map=placeholders_map)


def mask_text_batch(text_and_language_array: List[Union[str, Dict[str, Any]]]) -> List[Dict[str, Any]]:
    """
    Batch mask: items are strings or dicts with { text, language }.
    Returns list of { text: masked_text, maskMeta: bytes }.
    """
    _ensure_ready()
    out: List[Dict[str, Any]] = []
    for it in text_and_language_array:
        if isinstance(it, str):
            masked, meta = mask_text(it, None)
        else:
            text = str((it or {}).get("text", "") or "")
            language = (it or {}).get("language")
            masked, meta = mask_text(text, language)
        out.append({"text": masked, "maskMeta": meta})
    return out


def restore_text_batch(text_and_mask_meta_array: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """
    Batch restore: items are dicts { text: masked_text, maskMeta }.
    Returns list of { text: restored }.
    """
    _ensure_ready()
    out: List[Dict[str, Any]] = []
    for it in text_and_mask_meta_array:
        masked = str((it or {}).get("text", "") or "")
        meta = (it or {}).get("maskMeta")
        out.append({"text": restore_text(masked, meta)})
    return out


def get_pii_spans(input_text: str, language: Optional[str] = None) -> List[MatchedPIISpan]:
    """
    Return spans compatible with MatchedPIISpan from js.
    """
    _ensure_ready()
    lang_to_use = _select_language(input_text, language)
    spans = _ANALYZER.analyze(text=str(input_text or ""), language=lang_to_use.split("-")[0])
    out: List[MatchedPIISpan] = []
    for idx, s in enumerate(spans, start=1):
        out.append(
            MatchedPIISpan(
                entity_id=idx,
                entity_type=_entity_type_str_to_code(getattr(s, "entity_type", "")),
                matched_start=int(getattr(s, "start", 0)),
                matched_end=int(getattr(s, "end", 0)),
            )
        )
    return out


