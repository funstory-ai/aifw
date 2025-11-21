"""
NER utilities for aifw-py.

This module provides a minimal interface analogous to aifw-js/libner.js:
- init_env(opts)
- build_ner_pipeline(model_id, options)

Internally, it uses Python transformers (tokenizer + model) to generate token classification logits,
and reproduces the offset mapping/merging behavior similar to aifw-js/libner.js.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Dict, List, Optional, Tuple
import logging

from transformers import AutoTokenizer
import numpy as np
import os
from typing import Any

logger = logging.getLogger(__name__)


_ENV_STATE: Dict[str, Any] = {
    "modelsBase": None,
}

_MODELS_BASE: Optional[str] = None


def init_env(opts: Optional[Dict[str, Any]] = None) -> None:
    """
    Initialize underlying environment.
    Kept for API parity with aifw-js; options are accepted but not required.
    """
    global _ENV_STATE, _MODELS_BASE
    opts = opts or {}
    _ENV_STATE = {
        "modelsBase": opts.get("modelsBase"),
    }
    mb = _ENV_STATE.get("modelsBase")
    _MODELS_BASE = str(mb) if isinstance(mb, str) and mb else None
    logger.info("[aifw-py] init_env completed; modelsBase=%s", _MODELS_BASE or "(unset)")


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

    def __init__(self, ort_session: Optional[Any], tokenizer: Optional[AutoTokenizer], id2label: Dict[int, str], lang_hint: Optional[str] = None):
        self.ort_session = ort_session
        self.tokenizer = tokenizer
        self.id2label = id2label
        self._lang_hint = (lang_hint or "en").lower()

    async def run(self, text: str, opts: Optional[Dict[str, Any]] = None) -> List[NerItem]:
        """
        Re-implement token classification similar to JS:
        - Tokenize text
        - Run ONNX model (quantized) via onnxruntime
        - Softmax per-token to get label + score
        - Compute offsets on baseTextForOffsets using tokens (with optional tokenTransform)
        - Merge contiguous items of same entity
        """
        opts = opts or {}
        ignore_labels: List[str] = opts.get("ignore_labels", ["O"])
        offset_text: Optional[str] = opts.get("offsetText")
        token_transform = opts.get("tokenTransform")

        if self.ort_session is None or self.tokenizer is None:
            return []  # disabled pipeline

        enc = self.tokenizer(
            [text],
            return_offsets_mapping=True,
            return_tensors=None,
            padding=True,
            truncation=True,
            add_special_tokens=True,
        )
        input_ids = np.array(enc["input_ids"], dtype=np.int64)  # [1, seq_len]
        attention_mask = np.array(enc.get("attention_mask", [[1] * len(enc["input_ids"][0])]), dtype=np.int64)
        token_type_ids = enc.get("token_type_ids")
        if token_type_ids is not None:
            token_type_ids = np.array(token_type_ids, dtype=np.int64)

        # Prepare feed dict (robust to differing input names)
        feed = {}
        for inp in self.ort_session.get_inputs():
            name = inp.name
            if name in ("input_ids", "input_ids:0"):
                feed[name] = input_ids
            elif name in ("attention_mask", "attention_mask:0"):
                feed[name] = attention_mask
            elif name in ("token_type_ids", "token_type_ids:0") and token_type_ids is not None:
                feed[name] = token_type_ids
            elif name not in feed:
                # Fallback: try mapping by known keys
                if "input_ids" in name:
                    feed[name] = input_ids
                elif "attention_mask" in name:
                    feed[name] = attention_mask
                elif "token_type_ids" in name and token_type_ids is not None:
                    feed[name] = token_type_ids

        outputs = self.ort_session.run(None, feed)
        # Assume first output is logits: [1, seq_len, num_labels]
        logits = outputs[0]
        if logits.ndim == 3:
            logits = logits[0]
        seq_len = logits.shape[0]
        num_labels = logits.shape[1]

        # Plain tokens from ids (skip special, map '##' prefixes for BERT)
        tokens_plain: List[str] = []
        seq_index_to_plain: List[int] = [-1] * seq_len
        # Build tokens via ids; rely on tokenizer's convert_ids_to_tokens
        ids_row = input_ids[0]
        for j in range(seq_len):
            token_str = self.tokenizer.convert_ids_to_tokens(int(ids_row[j]))
            # Skip special tokens that often begin with [ or are empty
            if not token_str or token_str.startswith("[") and token_str.endswith("]"):
                continue
            if token_str.startswith("##"):
                token_str = token_str[2:]
            plain_idx = len(tokens_plain)
            seq_index_to_plain[j] = plain_idx
            tokens_plain.append(token_str)

        if callable(token_transform):
            tokens_plain = [token_transform(t) or t for t in tokens_plain]

        base_text_for_offsets = offset_text if isinstance(offset_text, str) else text
        offsets = compute_offsets_from_tokens(base_text_for_offsets, tokens_plain)

        items_raw: List[Tuple[int, str, float, str, int, int]] = []
        for j in range(seq_len):
            # softmax
            row = logits[j]
            max_idx = int(np.argmax(row))
            # numerical stable softmax
            max_val = float(np.max(row))
            exp = np.exp(row - max_val)
            sum_exp = float(np.sum(exp))
            score = float(exp[max_idx] / sum_exp) if sum_exp > 0 else 0.0
            entity = self.id2label.get(max_idx, f"LABEL_{max_idx}")
            if entity in ignore_labels:
                continue
            plain_idx = seq_index_to_plain[j]
            if plain_idx < 0 or plain_idx >= len(tokens_plain):
                continue
            word = tokens_plain[plain_idx]
            off = offsets[plain_idx] if 0 <= plain_idx < len(offsets) else (0, 0)
            items_raw.append((j, entity, score, word, int(off[0]), int(off[1])))

        # Merge contiguous same-entity segments
        items: List[NerItem] = []
        cur: Optional[NerItem] = None
        count = 0
        def core_label(s: str) -> str:
            if s.startswith("B-") or s.startswith("I-") or s.startswith("E-") or s.startswith("S-"):
                return s[2:]
            return s
        for (idx_j, ent, sc, wd, st, ed) in items_raw:
            if cur is None:
                cur = NerItem(entity=ent, score=sc, index=idx_j, word=wd, start=st, end=ed)
                count = 1
                continue
            same = core_label(cur.entity) == core_label(ent)
            contiguous = (cur.end == st)
            if same and contiguous:
                cur.word = cur.word + wd
                cur.end = ed
                cur.score = (cur.score * count + sc) / (count + 1)
                count += 1
            else:
                items.append(cur)
                cur = NerItem(entity=ent, score=sc, index=idx_j, word=wd, start=st, end=ed)
                count = 1
        if cur is not None:
            items.append(cur)
        return items


# Supported model ids for parity.
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
    Build a transformers-based token classification pipeline, aligned with JS expectations.
    """
    base = _MODELS_BASE
    lang_hint = "zh" if ("chinese" in model_id.lower() or "ckiplab" in model_id.lower()) else "en"

    # If modelsBase not provided, or local path missing, return a no-op pipeline
    class _NoopPipe(TokenClassificationPipelinePy):
        def __init__(self):
            super().__init__(model=None, tokenizer=None, lang_hint=lang_hint)
        async def run(self, text: str, opts: Optional[Dict[str, Any]] = None) -> List[NerItem]:
            return []

    if not base:
        logger.info("[aifw-py] modelsBase not set; NER pipeline will be disabled (regex-only).")
        return _NoopPipe()
    model_dir = os.path.join(base.rstrip("/"), model_id)
    if not os.path.isdir(model_dir):
        logger.warning("[aifw-py] model path not found: %s; NER pipeline disabled (regex-only).", model_dir)
        return _NoopPipe()
    onnx_path = os.path.join(model_dir, "onnx", "model_quantized.onnx")
    if not os.path.isfile(onnx_path):
        logger.warning("[aifw-py] ONNX model not found: %s; NER pipeline disabled (regex-only).", onnx_path)
        return _NoopPipe()
    try:
        tokenizer = AutoTokenizer.from_pretrained(model_dir, local_files_only=True, trust_remote_code=False)
    except Exception as e:
        logger.warning("[aifw-py] failed to load tokenizer at %s: %s; NER pipeline disabled.", model_dir, e)
        return _NoopPipe()

    # Load id2label from config.json to recover labels like "B-PER", "I-ORG", ...
    id2label: Dict[int, str] = {}
    config_path = os.path.join(model_dir, "config.json")
    if os.path.isfile(config_path):
        import json
        try:
            with open(config_path, "r", encoding="utf-8") as f:
                cfg_json = json.load(f)
            raw = cfg_json.get("id2label") or {}
            if isinstance(raw, dict):
                # Keys may be int or stringified int
                id2label = {int(k): str(v) for k, v in raw.items()}
        except Exception as e:
            logger.warning("[aifw-py] failed to load id2label from %s: %s", config_path, e)
    if not id2label:
        logger.warning("[aifw-py] id2label not found in %s; NER entities will use LABEL_x and may not map to PII types.", config_path)

    # Defer onnxruntime import to runtime; make optional
    try:
        import onnxruntime as ort  # type: ignore
        # Create ONNX Runtime session (CPU)
        sess_options = ort.SessionOptions()
        ort_session = ort.InferenceSession(onnx_path, sess_options, providers=["CPUExecutionProvider"])
        return TokenClassificationPipelinePy(ort_session=ort_session, tokenizer=tokenizer, id2label=id2label, lang_hint=lang_hint)
    except Exception as e:
        logger.warning("[aifw-py] failed to create onnxruntime session for %s: %s; NER pipeline disabled.", onnx_path, e)
        return _NoopPipe()


# ---- Helpers ported from JS offset logic ----
def strip_accents(s: str) -> str:
    try:
        import unicodedata
        return "".join(ch for ch in unicodedata.normalize("NFD", s) if not unicodedata.combining(ch))
    except Exception:
        return s


def is_connector_punct(ch: str) -> bool:
    import re
    return re.match(r"[-'`\u2010-\u2015\u2212\u00B7\u30FB\u2043\u2219]", ch) is not None


def build_stripped_map(s: str) -> Tuple[str, List[int]]:
    out_chars: List[str] = []
    mapping: List[int] = []
    i = 0
    while i < len(s):
        ch = s[i]
        norm = ch
        try:
            import unicodedata
            norm = unicodedata.normalize("NFD", ch)
        except Exception:
            pass
        for c in norm:
            try:
                import unicodedata
                if unicodedata.combining(c):
                    continue
            except Exception:
                pass
            if is_connector_punct(c):
                continue
            out_chars.append(c)
            mapping.append(i)
        i += 1
    return "".join(out_chars), mapping


def find_stripped_index_at_or_after(mapping: List[int], orig_index: int) -> int:
    lo, hi = 0, len(mapping)
    while lo < hi:
        mid = (lo + hi) >> 1
        if mapping[mid] < orig_index:
            lo = mid + 1
        else:
            hi = mid
    return lo


def compute_offsets_from_tokens(text: str, tokens: List[str]) -> List[Tuple[int, int]]:
    offsets: List[Tuple[int, int]] = [(0, 0)] * len(tokens)
    lower_text = text.lower()
    stripped, map_stripped_to_orig = build_stripped_map(lower_text)
    cursor_lower = 0
    cursor_stripped = 0
    for i, full in enumerate(tokens):
        raw = (full or "")
        if raw.startswith("##"):
            raw = raw[2:]
        if not raw:
            offsets[i] = (cursor_lower, cursor_lower)
            continue
        tok_lower = raw.lower()
        p = lower_text.find(tok_lower, cursor_lower)
        if p == -1:
            p = lower_text.find(tok_lower)
        if p != -1:
            s = p
            e = p + len(raw)
            offsets[i] = (s, e)
            cursor_lower = e
            cursor_stripped = find_stripped_index_at_or_after(map_stripped_to_orig, e)
            continue
        tok_stripped = strip_accents(tok_lower)
        if tok_stripped:
            sp = stripped.find(tok_stripped, cursor_stripped)
            if sp == -1:
                sp = stripped.find(tok_stripped)
            if sp != -1:
                start_orig = map_stripped_to_orig[sp] if sp < len(map_stripped_to_orig) else 0
                after = sp + len(tok_stripped)
                end_orig = map_stripped_to_orig[after] if after < len(map_stripped_to_orig) else len(text)
                offsets[i] = (start_orig, end_orig)
                cursor_lower = end_orig
                cursor_stripped = after
                continue
        offsets[i] = (cursor_lower, cursor_lower)
    return offsets


