"""
Public API for aifw-py.

This module mirrors the high-level API of aifw-js:
- init(options)
- deinit()
- config(mask_cfg)
- detect_language(text)
- mask_text(text, language)
- restore_text(masked_text, mask_meta)
- mask_text_batch(items)
- restore_text_batch(items)
- get_pii_spans(text, language)
"""

from .libaifw import (
    init,
    deinit,
    config,
    detect_language,
    mask_text,
    restore_text,
    mask_text_batch,
    restore_text_batch,
    get_pii_spans,
    MatchedPIISpan,
)

__all__ = [
    "init",
    "deinit",
    "config",
    "detect_language",
    "mask_text",
    "restore_text",
    "mask_text_batch",
    "restore_text_batch",
    "get_pii_spans",
    "MatchedPIISpan",
]


