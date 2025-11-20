"""
NER utilities for aifw-py.

This module provides a minimal interface analogous to aifw-js/libner.js:
- init_env(opts)
- build_ner_pipeline(model_id, options)

Internally, it uses Presidio-based Analyzer to generate entity spans.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Dict, List, Optional
import logging

# Reuse AnalyzerWrapper from py-origin
from ...py-origin.services.app.analyzer import AnalyzerWrapper, EntitySpan

logger = logging.getLogger(__name__)


_ENV_STATE: Dict[str, Any] = {
    "wasmBase": None,
    "modelsBase": None,
    "threads": None,
    "simd": None,
}

_ANALYZER: Optional[AnalyzerWrapper] = None


def init_env(opts: Optional[Dict[str, Any]] = None) -> None:
    """
    Initialize underlying environment.
    Kept for API parity with aifw-js; options are accepted but not required.
    """
    global _ENV_STATE, _ANALYZER
    opts = opts or {}
    _ENV_STATE = {
        "wasmBase": opts.get("wasmBase"),
        "modelsBase": opts.get("modelsBase"),
        "threads": opts.get("threads"),
        "simd": opts.get("simd"),
        "customCache": opts.get("customCache"),
    }
    if _ANALYZER is None:
        _ANALYZER = AnalyzerWrapper()
    logger.info("[aifw-py] init_env completed; opts=%s", {k: v for k, v in _ENV_STATE.items() if v is not None})


@dataclass
class NerItem:
    entity: str
    score: float
    index: int
    word: str
    start: int
    end: int


class TokenClassificationPipelinePy:
    """
    Lightweight analogue to the JS TokenClassificationPipeline.
    It emits items with fields: entity, score, index, word, start, end.
    """

    def __init__(self, analyzer: AnalyzerWrapper, lang_hint: Optional[str] = None):
        self._analyzer = analyzer
        self._lang_hint = (lang_hint or "en").lower()

    async def run(self, text: str, opts: Optional[Dict[str, Any]] = None) -> List[NerItem]:
        opts = opts or {}
        # ignore_labels not needed since analyzer already filters
        lang = self._lang_hint or "en"
        spans: List[EntitySpan] = self._analyzer.analyze(text=text, language=lang)
        items: List[NerItem] = []
        for i, s in enumerate(spans):
            word = text[s.start : s.end]
            items.append(
                NerItem(
                    entity=s.entity_type,
                    score=float(getattr(s, "score", 0.0)),
                    index=i,
                    word=word,
                    start=int(s.start),
                    end=int(s.end),
                )
            )
        return items


# Supported model ids for parity; values are accepted but not used in Python implementation.
SUPPORTED_MODELS = {
    "funstory-ai/neurobert-mini",
    "ckiplab/bert-tiny-chinese-ner",
    "Xenova/distilbert-base-cased-finetuned-conll03-english",
    "gagan3012/bert-tiny-finetuned-ner",
    "dslim/distilbert-NER",
    "boltuix/NeuroBERT-Mini",
    "hfl/minirbt-h256",
    "dmis-lab/TinyPubMedBERT-v1.0",
    "boltuix/NeuroBERT-Small",
}


async def build_ner_pipeline(model_id: str, options: Optional[Dict[str, Any]] = None) -> TokenClassificationPipelinePy:
    """
    Build a pipeline. In Python we return a wrapper over AnalyzerWrapper.
    model_id and options are accepted for API parity.
    """
    if model_id not in SUPPORTED_MODELS:
        logger.warning("Model id %s not in known set; continuing since Python backend does not require it.", model_id)
    if _ANALYZER is None:
        init_env({})
    # Heuristic language hint by model id
    lang_hint = "zh" if "chinese" in model_id.lower() or "ckiplab" in model_id.lower() else "en"
    return TokenClassificationPipelinePy(_ANALYZER, lang_hint=lang_hint)


