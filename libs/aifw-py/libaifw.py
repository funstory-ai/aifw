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
- Uses Python transformers for NER token classification.
- Uses wasmtime to load and call Zig core WASM (same as js lib flows).
"""
from __future__ import annotations

import logging
from dataclasses import dataclass
from typing import Any, Dict, List, Optional, Tuple

from .libner import init_env as ner_init_env, build_ner_pipeline
from langdetect import detect as langdetect_detect
import os
import sys
import struct
import ctypes
from ctypes import c_void_p, c_uint8, c_uint16, c_uint32, c_size_t, c_char_p, POINTER, byref
from typing import Union

logger = logging.getLogger(__name__)


# Global state
_NER_EN = None
_NER_ZH = None
_SESSION_OPEN = False
_CORE = None  # ctypes.CDLL
_CORE_SHUTDOWN_CALLED = False
_SESSION_HANDLE = c_void_p(0)


# Mirror core/aifw_core.zig extern structs used in session configuration.
class MaskConfig(ctypes.Structure):
    _fields_ = [
        ("enable_mask_bits", c_uint32),
    ]


class RestoreConfig(ctypes.Structure):
    # Currently empty extern struct
    _fields_: list[tuple[str, Any]] = []


class SessionConfig(ctypes.Structure):
    _fields_ = [
        ("mask_config", MaskConfig),
        ("restore_config", RestoreConfig),
    ]


# Map core EntityType enum id to string tag name (must stay in sync with core/recog_entity.zig)
_ENTITY_TYPE_ID_TO_NAME: Dict[int, str] = {
    0: "NONE",
    1: "PHYSICAL_ADDRESS",
    2: "EMAIL_ADDRESS",
    3: "ORGANIZATION",
    4: "USER_MAME",
    5: "PHONE_NUMBER",
    6: "BANK_NUMBER",
    7: "PAYMENT",
    8: "VERIFICATION_CODE",
    9: "PASSWORD",
    10: "RANDOM_SEED",
    11: "PRIVATE_KEY",
    12: "URL_ADDRESS",
}


def _entity_type_id_to_name(t: Any) -> str:
    try:
        iv = int(t)
    except Exception:
        return str(t)
    return _ENTITY_TYPE_ID_TO_NAME.get(iv, f"TYPE_{iv}")


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


def detect_language(text: str) -> str:
    # Use langdetect for primary language detection
    try:
        code = langdetect_detect(text or "")
    except Exception:
        code = "en"
    lang = "zh" if code.startswith("zh") else (code or "en")
    if not lang.startswith("zh"):
        return lang
    script_quick = _quick_script_zh(text or "")
    if script_quick:
        return f"zh-{script_quick}"
    script = _decide_script_with_opencc(text or "")
    return f"zh-{script}"


def init(options: Optional[Dict[str, Any]] = None) -> None:
    """
    Initialize aifw-py runtime.
    options are accepted for API parity; unknown keys are ignored.
    """
    global _NER_EN, _NER_ZH, _SESSION_OPEN, _WASM, _SESSION_HANDLE
    if _SESSION_OPEN:
        return
    options = options or {}
    # Initialize ner env and two pipelines
    models_base = None
    if isinstance(options.get("models"), dict):
        models_base = options["models"].get("modelsBase")
    if not models_base:
        models_base = os.environ.get("AIFW_MODELS_BASE")
    if not models_base:
        logger.warning(
            "[aifw-py] modelsBase is not configured (no options['models']['modelsBase'] "
            "and AIFW_MODELS_BASE is not set); NER models will NOT be loaded. "
            "Only regex-based PII detection will be used."
        )
    ner_init_env({
        "modelsBase": models_base,
    })
    _NER_EN = build_ner_pipeline("funstory-ai/neurobert-mini", {"quantized": True})
    _NER_ZH = build_ner_pipeline("ckiplab/bert-tiny-chinese-ner", {"quantized": True})
    # Load native core via ctypes
    _load_core_native(options or {})
    # Create session
    mask_bits = _get_mask_bits_from_mask_config(options.get("maskConfig") or {})
    _SESSION_HANDLE = _create_session(mask_bits)
    _SESSION_OPEN = True
    logger.info("[aifw-py] init complete.")


def deinit() -> None:
    """Tear down runtime."""
    global _NER_EN, _NER_ZH, _SESSION_OPEN, _CORE, _CORE_SHUTDOWN_CALLED, _SESSION_HANDLE
    try:
        _destroy_session()
    except Exception:
        pass
    try:
        # Only call shutdown once, even if deinit is called multiple times
        if _CORE_SHUTDOWN_CALLED:
            logger.warning("[aifw-py] shutdown already called, skipping")
        elif _CORE:
            _CORE.aifw_shutdown()
            _CORE_SHUTDOWN_CALLED = True
    except Exception:
        pass
    _SESSION_HANDLE = c_void_p(0)
    _NER_EN = None
    _NER_ZH = None
    _SESSION_OPEN = False


def config(mask_cfg: Dict[str, Any]) -> None:
    """
    Configure the session with new mask configuration.
    """
    global _SESSION_OPEN, _SESSION_HANDLE
    # Ensure core and session are ready
    _ensure_ready()
    # Compute new mask bits from config (starting from core default bits)
    new_bits = _get_mask_bits_from_mask_config(mask_cfg or {})
    sess_cfg = SessionConfig(
        mask_config=MaskConfig(enable_mask_bits=new_bits),
        restore_config=RestoreConfig(),
    )
    _CORE.aifw_session_config(_SESSION_HANDLE, byref(sess_cfg))
    logger.info("[aifw-py] mask config updated.")


def _select_language(input_text: str, language: Optional[str]) -> str:
    lang_to_use = language or ""
    if not lang_to_use or lang_to_use.lower() == "auto":
        try:
            code = langdetect_detect(input_text or "")
        except Exception:
            code = "en"
        if code.startswith("zh"):
            script = _quick_script_zh(input_text or "") or "Hans"
            return "zh-TW" if script == "Hant" else "zh-CN"
        return code or "en"
    return lang_to_use


@dataclass
class MatchedPIISpan:
    """
    PII span returned by get_pii_spans.

    - entity_id: numeric id assigned by core
    - entity_type: string tag name (e.g. "EMAIL_ADDRESS"), converted from core enum id
    - matched_start / matched_end: character indices in the original input text (not UTF-8 bytes)
    - score: confidence score from 0.0 to 1.0
    """
    entity_id: int
    entity_type: str
    matched_start: int
    matched_end: int
    score: float


def _session_handle_is_valid() -> bool:
    """
    Return True if session handle points to a valid core Session.
    Handles both ctypes.c_void_p and raw int usages.
    """
    try:
        h = _SESSION_HANDLE
        if h is None:
            return False
        # ctypes.c_void_p has .value; some environments may hold raw int
        if isinstance(h, ctypes.c_void_p):
            return bool(h.value)
        return int(h) != 0
    except Exception:
        return False


def _ensure_ready():
    if (not _SESSION_OPEN) or (not _CORE) or (not _session_handle_is_valid()):
        # Log detailed state to help debugging initialization issues
        hv = None
        try:
            hv = getattr(_SESSION_HANDLE, "value", None)
        except Exception:
            hv = None
        logger.error(
            "AIFW not initialized; SESSION_OPEN=%s CORE=%s SESSION_HANDLE=%s HANDLE_VALUE=%s",
            _SESSION_OPEN, _CORE, _SESSION_HANDLE, hv
        )
        raise RuntimeError("AIFW not initialized; call init() first")


def mask_text(input_text: str, language: Optional[str] = None) -> Tuple[str, bytes]:
    """
    Mirror js: build ner entities, call core wasm mask_and_out_meta, copy meta bytes and free core buffer.
    """
    _ensure_ready()
    lang_to_use = _select_language(input_text, language)
    ner_pipe = _select_ner(lang_to_use)
    # zh simplified case: convert to traditional for zh model to improve recognition; map offsets back
    run_text = input_text
    run_opts = {}
    if ner_pipe is _NER_ZH and _is_zh_simplified(lang_to_use):
        try:
            from opencc import OpenCC
            s2t = OpenCC("s2t")
            t2s = OpenCC("t2s")
            run_text = s2t.convert(input_text)
            run_opts = {"offsetText": input_text, "tokenTransform": (lambda s: t2s.convert(s))}
        except Exception:
            pass
    items = ner_pipe.run(run_text, run_opts)
    ner_buf = _build_ner_entities_buffer(items, input_text)
    try:
        # Prepare inputs
        in_c = ctypes.create_string_buffer((input_text or "").encode("utf-8") + b"\x00")
        out_masked = c_void_p()
        out_meta = c_void_p()
        lang_enum = _language_enum(lang_to_use)
        rc = _CORE.aifw_session_mask_and_out_meta(
            _SESSION_HANDLE,
            ctypes.cast(in_c, c_char_p),
            ctypes.cast(ner_buf["ptr"], c_void_p),
            c_uint32(ner_buf["count"]),
            c_uint8(lang_enum),
            byref(out_masked),
            byref(out_meta),
        )
        if rc != 0:
            raise RuntimeError(f"mask failed rc={rc}")
        masked_text = ctypes.string_at(out_masked).decode("utf-8", errors="ignore")
        _CORE.aifw_string_free(out_masked)
        # mask meta: read length u32 then bytes (allocated as u8[], align=1)
        total_len = struct.unpack("<I", ctypes.string_at(out_meta, 4))[0]
        meta_bytes = ctypes.string_at(out_meta, total_len)
        _CORE.aifw_free_sized(out_meta, c_size_t(total_len), c_uint8(1))
        return masked_text, meta_bytes
    finally:
        # ner_buf created in Python memory; no core free needed
        pass


def restore_text(masked_text: str, mask_meta: bytes) -> str:
    """
    Restore text: upload serialized meta bytes to wasm memory; core frees it.
    """
    _ensure_ready()
    in_masked = ctypes.create_string_buffer((masked_text or "").encode("utf-8") + b"\x00")
    meta_ptr = _CORE.aifw_malloc(c_size_t(len(mask_meta)))
    ctypes.memmove(meta_ptr, mask_meta, len(mask_meta))
    out_restored = c_void_p()
    rc = _CORE.aifw_session_restore_with_meta(_SESSION_HANDLE, ctypes.cast(in_masked, c_char_p), meta_ptr, byref(out_restored))
    if rc != 0:
        raise RuntimeError(f"restore failed rc={rc}")
    if int(out_restored.value or 0) == 0:
        return ""
    restored = ctypes.string_at(out_restored).decode("utf-8", errors="ignore")
    _CORE.aifw_string_free(out_restored)
    return restored


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
    Return spans compatible with MatchedPIISpan from js by calling core get_pii_spans.
    """
    _ensure_ready()
    lang_to_use = _select_language(input_text, language)
    ner_pipe = _select_ner(lang_to_use)
    run_text = input_text
    run_opts = {}
    if ner_pipe is _NER_ZH and _is_zh_simplified(lang_to_use):
        try:
            from opencc import OpenCC
            s2t = OpenCC("s2t")
            t2s = OpenCC("t2s")
            run_text = s2t.convert(input_text)
            run_opts = {"offsetText": input_text, "tokenTransform": (lambda s: t2s.convert(s))}
        except Exception:
            pass
    items = ner_pipe.run(run_text, run_opts)
    ner_buf = _build_ner_entities_buffer(items, input_text)
    try:
        in_c = ctypes.create_string_buffer((input_text or "").encode("utf-8") + b"\x00")
        out_spans = c_void_p()
        out_count = c_uint32(0)
        lang_enum = _language_enum(lang_to_use)
        rc = _CORE.aifw_session_get_pii_spans(
            _SESSION_HANDLE,
            ctypes.cast(in_c, c_char_p),
            ctypes.cast(ner_buf["ptr"], c_void_p),
            c_uint32(ner_buf["count"]),
            c_uint8(lang_enum),
            byref(out_spans),
            byref(out_count),
        )
        if rc != 0:
            raise RuntimeError(f"get_pii_spans failed rc={rc}")
        # MatchedPIISpan extern struct layout in core/aifw_core.zig (UTF-8 byte offsets):
        #   u32 entity_id;
        #   EntityType entity_type; // u8 + 3-byte padding
        #   u32 matched_start;  // byte offset in UTF-8
        #   u32 matched_end;    // byte offset in UTF-8
        #   f32 score;
        # Total size: 20 bytes, alignment 4.
        span_size = 20
        raw = ctypes.string_at(out_spans, out_count.value * span_size)

        # Build byte_offset -> character index map for the original input_text.
        utf8 = (input_text or "").encode("utf-8")
        n_bytes = len(utf8)
        byte_to_char: List[int] = [0] * (n_bytes + 1)
        byte_pos = 0
        for char_index, ch in enumerate(input_text):
            byte_to_char[byte_pos] = char_index
            byte_pos += len(ch.encode("utf-8"))
        # Ensure terminal position maps to len(text)
        if byte_pos == n_bytes:
            byte_to_char[n_bytes] = len(input_text)
        else:
            byte_to_char[-1] = len(input_text)

        def _byte_off_to_char(off: int) -> int:
            if off <= 0:
                return 0
            if off >= len(byte_to_char):
                return len(input_text)
            idx = off
            # If offset does not land exactly on a recorded boundary,
            # clamp to the nearest previous character boundary.
            while idx > 0 and byte_to_char[idx] == 0:
                idx -= 1
            return byte_to_char[idx]

        out: List[MatchedPIISpan] = []
        for i in range(out_count.value):
            base = i * span_size
            entity_id = int(struct.unpack_from("<I", raw, base + 0)[0])
            entity_type_id = int(struct.unpack_from("<B", raw, base + 4)[0])
            b_start = int(struct.unpack_from("<I", raw, base + 8)[0])
            b_end = int(struct.unpack_from("<I", raw, base + 12)[0])
            score = float(struct.unpack_from("<f", raw, base + 16)[0])
            start = _byte_off_to_char(b_start)
            end = _byte_off_to_char(b_end)
            entity_type_name = _entity_type_id_to_name(entity_type_id)
            out.append(MatchedPIISpan(entity_id, entity_type_name, start, end, score))
        if int(out_spans.value or 0) and out_count.value:
            _CORE.aifw_free_sized(out_spans, c_size_t(out_count.value * span_size), c_uint8(4))
        return out
    finally:
        pass


# ---- Internal helpers mirroring js ----
def _select_ner(language: str):
    l = (language or "").lower()
    if l == "zh" or l.startswith("zh-"):
        return _NER_ZH or _NER_EN
    return _NER_EN


def _is_zh_simplified(language: str) -> bool:
    l = (language or "").lower()
    if l == "zh":
        return True
    if l == "zh-cn" or l == "zh-hans":
        return True
    if not l.startswith("zh-"):
        return False
    if "hant" in l or "tw" in l or "hk" in l:
        return False
    return True


def _language_enum(language: str) -> int:
    l = (language or "").lower()
    if l.startswith("en"):
        return 1
    if l.startswith("ja"):
        return 2
    if l.startswith("ko"):
        return 3
    if l == "zh":
        return 4
    if l == "zh-cn":
        return 5
    if l == "zh-tw":
        return 6
    if l == "zh-hk":
        return 7
    if l == "zh-hans":
        return 8
    if l == "zh-hant":
        return 9
    if l.startswith("fr"):
        return 10
    if l.startswith("de"):
        return 11
    if l.startswith("ru"):
        return 12
    if l.startswith("es"):
        return 13
    if l.startswith("it"):
        return 14
    if l.startswith("ar"):
        return 15
    if l.startswith("pt"):
        return 16
    return 0


def _to_core_and_tag(label: str) -> Tuple[str, int]:
    s = str(label or "")
    if s.startswith("B-") or s.startswith("S-"):
        return s[2:], 1
    if s.startswith("I-") or s.startswith("E-"):
        return s[2:], 2
    if s:
        return s, 0
    return "MISC", 0


def _to_entity_type(entity_type_str: str) -> int:
    c = entity_type_str.upper()
    if c in ("PER", "PERSON"):
        return 4
    if c == "ORG":
        return 3
    if c in ("LOC", "GPE", "FAC", "ADDRESS"):
        return 1
    if c == "MISC":
        return 0
    return 0


def _build_ner_entities_buffer(items: List[Dict[str, Any]] or List[Any], js_text: str) -> Dict[str, Any]:
    if not items:
        return {"ptr": c_void_p(0), "count": 0, "owned": [], "byteSize": 0, "keep": None}
    struct_size = 20
    count = len(items)
    total = struct_size * count
    ba = bytearray(total)
    cbuf = (ctypes.c_char * total).from_buffer(ba)

    def compute_utf8_offset_map(text: str) -> List[int]:
        mapping: List[int] = [0] * (len(text) + 1)
        bpos = 0
        i = 0
        while i < len(text):
            mapping[i] = bpos
            cp = ord(text[i])
            cu_len = 2 if cp > 0xFFFF else 1
            if cp <= 0x7F:
                utf8_len = 1
            elif cp <= 0x7FF:
                utf8_len = 2
            elif cp <= 0xFFFF:
                utf8_len = 3
            else:
                utf8_len = 4
            bpos += utf8_len
            i += cu_len
        mapping[len(text)] = bpos
        return mapping

    utf8_map = compute_utf8_offset_map(js_text)
    text_len = len(js_text)

    for i, it in enumerate(items):
        s = max(0, min(text_len, int(getattr(it, "start", getattr(it, "start", 0)))))
        e = max(s, min(text_len, int(getattr(it, "end", getattr(it, "end", 0)))))
        s_byte = utf8_map[s] if s < len(utf8_map) else 0
        e_byte = utf8_map[e] if e < len(utf8_map) else utf8_map[text_len]
        entity_raw = getattr(it, "entity", getattr(it, "entity", ""))
        core, tag_val = _to_core_and_tag(entity_raw)
        entity_type_val = _to_entity_type(core)
        # pack struct: <BBH f I I I
        struct.pack_into("<BBHfIII", ba, i * struct_size,
                         int(entity_type_val) & 0xFF,
                         int(tag_val) & 0xFF,
                         0,
                         float(getattr(it, "score", 0.0)),
                         int(getattr(it, "index", 0)),
                         int(s_byte),
                         int(e_byte))
    return {
        "ptr": ctypes.cast(ctypes.addressof(cbuf), c_void_p),
        "count": count,
        "owned": [],
        "byteSize": total,
        "keep": (ba, cbuf),
    }

# ---- Native core wiring via ctypes ----
def _load_core_native(options: Dict[str, Any]) -> None:
    global _CORE
    # Project root = <repo>/ (this file is at libs/aifw-py/libaifw.py)
    project_root = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
    lib_dir = os.path.join(project_root, "zig-out", "lib")
    # Allow override by env var
    override = os.environ.get("AIFW_CORE_LIB")
    if override and os.path.exists(override):
        lib_path = override
    else:
        # Platform-specific names
        if sys.platform == "darwin":
            cand = os.path.join(lib_dir, "liboneaifw_core.dylib")
        elif sys.platform.startswith("linux"):
            cand = os.path.join(lib_dir, "liboneaifw_core.so")
        elif os.name == "nt":
            cand = os.path.join(lib_dir, "oneaifw_core.dll")
        else:
            cand = os.path.join(lib_dir, "liboneaifw_core.dylib")
        lib_path = cand
    if not os.path.exists(lib_path):
        raise RuntimeError(
            "Native core library not found.\n"
            f"Expected at: {lib_path}\n"
            "Please build a shared library (not .a) and/or set env AIFW_CORE_LIB to the built file.\n"
            "Example (macOS): zig build -Dshared=true  -> zig-out/lib/liboneaifw_core.dylib"
        )
    _CORE = ctypes.CDLL(lib_path)
    _bind_core_signatures()


def _bind_core_signatures() -> None:
    # Basic
    _CORE.aifw_shutdown.restype = None
    _CORE.aifw_default_mask_bits.restype = c_uint32
    _CORE.aifw_malloc.argtypes = [c_size_t]
    _CORE.aifw_malloc.restype = c_void_p
    _CORE.aifw_free_sized.argtypes = [c_void_p, c_size_t, c_uint8]
    _CORE.aifw_free_sized.restype = None
    _CORE.aifw_string_free.argtypes = [c_void_p]
    _CORE.aifw_string_free.restype = None
    # Session
    _CORE.aifw_session_create.argtypes = [c_void_p]
    _CORE.aifw_session_create.restype = c_void_p
    _CORE.aifw_session_destroy.argtypes = [c_void_p]
    _CORE.aifw_session_destroy.restype = None
    _CORE.aifw_session_config.argtypes = [c_void_p, ctypes.POINTER(SessionConfig)]
    _CORE.aifw_session_config.restype = None
    # Mask / spans / restore
    _CORE.aifw_session_mask_and_out_meta.argtypes = [c_void_p, c_char_p, c_void_p, c_uint32, c_uint8, POINTER(c_void_p), POINTER(c_void_p)]
    _CORE.aifw_session_mask_and_out_meta.restype = c_uint16
    _CORE.aifw_session_get_pii_spans.argtypes = [c_void_p, c_char_p, c_void_p, c_uint32, c_uint8, POINTER(c_void_p), POINTER(c_uint32)]
    _CORE.aifw_session_get_pii_spans.restype = c_uint16
    _CORE.aifw_session_restore_with_meta.argtypes = [c_void_p, c_char_p, c_void_p, POINTER(c_void_p)]
    _CORE.aifw_session_restore_with_meta.restype = c_uint16


def _get_mask_bits_from_mask_config(mask_cfg: Dict[str, Any]) -> int:
    # Fetch default from core then apply flags
    mask_bits = int(_CORE.aifw_default_mask_bits())
    def apply(flag, bit):
        nonlocal mask_bits
        if flag is True:
            mask_bits |= bit
        elif flag is False:
            mask_bits &= ~bit
    ENABLE_MASK_ADDR_BIT = 1 << 0
    ENABLE_MASK_EMAIL_BIT = 1 << 1
    ENABLE_MASK_ORG_BIT = 1 << 2
    ENABLE_MASK_USER_NAME_BIT = 1 << 3
    ENABLE_MASK_PHONE_NUMBER_BIT = 1 << 4
    ENABLE_MASK_BANK_NUMBER_BIT = 1 << 5
    ENABLE_MASK_PAYMENT_BIT = 1 << 6
    ENABLE_MASK_VCODE_BIT = 1 << 7
    ENABLE_MASK_PASSWORD_BIT = 1 << 8
    ENABLE_MASK_RANDOM_SEED_BIT = 1 << 9
    ENABLE_MASK_PRIVATE_KEY_BIT = 1 << 10
    ENABLE_MASK_URL_ADDRESS_BIT = 1 << 11
    ENABLE_MASK_ALL_BITS = (
        ENABLE_MASK_ADDR_BIT | ENABLE_MASK_EMAIL_BIT | ENABLE_MASK_ORG_BIT | ENABLE_MASK_USER_NAME_BIT |
        ENABLE_MASK_PHONE_NUMBER_BIT | ENABLE_MASK_BANK_NUMBER_BIT | ENABLE_MASK_PAYMENT_BIT | ENABLE_MASK_VCODE_BIT |
        ENABLE_MASK_PASSWORD_BIT | ENABLE_MASK_RANDOM_SEED_BIT | ENABLE_MASK_PRIVATE_KEY_BIT | ENABLE_MASK_URL_ADDRESS_BIT
    )
    apply(mask_cfg.get("maskAddress"), ENABLE_MASK_ADDR_BIT)
    apply(mask_cfg.get("maskEmail"), ENABLE_MASK_EMAIL_BIT)
    apply(mask_cfg.get("maskOrganization"), ENABLE_MASK_ORG_BIT)
    apply(mask_cfg.get("maskUserName"), ENABLE_MASK_USER_NAME_BIT)
    apply(mask_cfg.get("maskPhoneNumber"), ENABLE_MASK_PHONE_NUMBER_BIT)
    apply(mask_cfg.get("maskBankNumber"), ENABLE_MASK_BANK_NUMBER_BIT)
    apply(mask_cfg.get("maskPayment"), ENABLE_MASK_PAYMENT_BIT)
    apply(mask_cfg.get("maskVerificationCode"), ENABLE_MASK_VCODE_BIT)
    apply(mask_cfg.get("maskPassword"), ENABLE_MASK_PASSWORD_BIT)
    apply(mask_cfg.get("maskRandomSeed"), ENABLE_MASK_RANDOM_SEED_BIT)
    apply(mask_cfg.get("maskPrivateKey"), ENABLE_MASK_PRIVATE_KEY_BIT)
    apply(mask_cfg.get("maskUrl"), ENABLE_MASK_URL_ADDRESS_BIT)
    apply(mask_cfg.get("maskAll"), ENABLE_MASK_ALL_BITS)
    return int(mask_bits) & 0xFFFFFFFF


def _create_session(mask_bits: int) -> int:
    # SessionInitArgs layout: u32 enable_mask_bits, u8 ner_recog_type, 3 padding
    init_buf = ctypes.create_string_buffer(8)
    struct.pack_into("<IB", init_buf, 0, int(mask_bits), 0)  # rest padding left zero
    handle = _CORE.aifw_session_create(ctypes.cast(ctypes.addressof(init_buf), c_void_p))
    if int(handle or 0) == 0:
        raise RuntimeError("session_create failed")
    return handle


def _destroy_session() -> None:
    """Destroy core session if exists."""
    global _SESSION_HANDLE
    try:
        h = _SESSION_HANDLE
        if h is None:
            return
        if isinstance(h, ctypes.c_void_p):
            if not h.value:
                return
            _CORE.aifw_session_destroy(h)
        else:
            # raw int pointer case
            if int(h) == 0:
                return
            _CORE.aifw_session_destroy(c_void_p(int(h)))
    finally:
        _SESSION_HANDLE = c_void_p(0)
