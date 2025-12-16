from presidio_anonymizer import AnonymizerEngine
from presidio_analyzer import RecognizerResult
from presidio_anonymizer.entities import OperatorConfig
from typing import List, Dict, Any, Optional
from dataclasses import dataclass
import logging
import sys
import re

logger = logging.getLogger(__name__)

@dataclass
class AnonymizeResult:
    text: str
    placeholdersMap: Dict[str, str]

class AnonymizerWrapper:
    def __init__(self, analyzer_wrapper):
        # Accept AnalyzerEngine instance; we'll use Presidio's Anonymizer for operators,
        # but also provide reversible placeholder flow.
        self.anonymizer = AnonymizerEngine()
        self.analyzer_wrapper = analyzer_wrapper
        # Runtime mask configuration (mirrors docs for /api/config -> maskConfig).
        # This wrapper enforces the policy by filtering analyzer spans before masking.
        self._mask_config: Dict[str, Any] = {}

    def set_mask_config(self, mask_config: Dict[str, Any]) -> None:
        """Update runtime mask configuration.

        mask_config schema mirrors JS maskConfig:
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
        if isinstance(mask_config, dict):
            self._mask_config = dict(mask_config)

    def _is_entity_enabled(self, entity_type: str) -> bool:
        """Return True if the entity type should be masked under current maskConfig."""
        cfg = self._mask_config or {}
        mask_all = cfg.get("maskAll")
        if isinstance(mask_all, bool):
            return mask_all

        # Defaults per docs: most true except address false.
        defaults: Dict[str, bool] = {
            "maskAddress": False,
            "maskEmail": True,
            "maskOrganization": True,
            "maskUserName": True,
            "maskPhoneNumber": True,
            "maskBankNumber": True,
            "maskPayment": True,
            "maskVerificationCode": True,
            "maskPassword": True,
            "maskRandomSeed": True,
            "maskPrivateKey": True,
            "maskUrl": True,
        }
        effective = dict(defaults)
        for k, v in cfg.items():
            if k in defaults and isinstance(v, bool):
                effective[k] = v

        # Map Presidio entity types to maskConfig keys
        mapping = {
            "PHYSICAL_ADDRESS": "maskAddress",
            "EMAIL_ADDRESS": "maskEmail",
            "ORGANIZATION": "maskOrganization",
            # Treat PERSON and USER_NAME as "maskUserName"
            "PERSON": "maskUserName",
            "USER_NAME": "maskUserName",
            "PHONE_NUMBER": "maskPhoneNumber",
            "BANK_NUMBER": "maskBankNumber",
            "PAYMENT": "maskPayment",
            "VERIFY_CODE": "maskVerificationCode",
            "PASSWORD": "maskPassword",
            "RANDOM_SEED": "maskRandomSeed",
            "PRIVATE_KEY": "maskPrivateKey",
            "URL": "maskUrl",
        }
        key = mapping.get(str(entity_type or "").upper())
        if not key:
            # For unknown entities, keep backward-compatible behavior: mask by default.
            return True
        return bool(effective.get(key, True))

    def anonymize(self, text: str, operators: Optional[Dict[str, Dict[str, Any]]] = None, language: str = 'en'):
        # Run analysis to get spans
        try:
            results: List[RecognizerResult] = self.analyzer_wrapper.analyze(text=text, language=language)
        except Exception:
            # Fallback to English recognizers if requested language lacks support
            logger.debug(f"anonymize: input_lang={language} fallback_to_en")
            results = self.analyzer_wrapper.analyze(text=text, language='en')
        logger.debug(f"anonymize: input_lang={language} raw_results={[ (r.entity_type, r.start, r.end, getattr(r,'score',None)) for r in results ]}")
        # Apply maskConfig filtering before anonymization
        if results:
            before = len(results)
            results = [r for r in results if self._is_entity_enabled(getattr(r, "entity_type", ""))]
            if before != len(results):
                logger.debug("anonymize: maskConfig filtered %s -> %s spans", before, len(results))
        # Build placeholders map and replace from end
        placeholders = {}
        new_text = text
        # If operators provided, run Presidio anonymizer to apply ops instead of placeholders for some types
        if operators:
            # Convert operators dict to OperatorConfig map
            op_configs = {}
            for k, v in operators.items():
                typ = v.get('type', 'replace')
                params = {kk: vv for kk, vv in v.items() if kk != 'type'}
                op_configs[k] = OperatorConfig(typ, params)
            # apply anonymizer (this will use original analyzer results)
            anonymized = self.anonymizer.anonymize(text=text, analyzer_results=results, operators=op_configs)
            return {'text': anonymized.text, 'placeholdersMap': placeholders}
        # Resolve overlapping/duplicate spans to avoid double-replacing same text.
        # Priority: higher score, longer span, earlier start.
        def priority_key(r: RecognizerResult):
            return (-float(getattr(r, 'score', 0.0)), -(r.end - r.start), r.start)

        def overlaps(a: RecognizerResult, b: RecognizerResult) -> bool:
            return not (a.end <= b.start or b.end <= a.start)

        selected: List[RecognizerResult] = []
        for cand in sorted(results, key=priority_key):
            if all(not overlaps(cand, s) for s in selected):
                selected.append(cand)
        logger.debug(f"anonymize: selected={[ (r.entity_type, r.start, r.end) for r in selected ]}")

        # Two-loop approach: assign IDs L→R, then replace R→L to avoid index shifts
        assigned = []
        counter = 0
        for r in sorted(selected, key=lambda x: x.start):
            counter += 1
            pii_id = f"{counter}"
            placeholder = f"__PII_{r.entity_type}_{pii_id}__"
            assigned.append((r, placeholder))
        for r, placeholder in sorted(assigned, key=lambda t: t[0].start, reverse=True):
            placeholders[placeholder] = text[r.start:r.end]
            new_text = new_text[:r.start] + placeholder + new_text[r.end:]
        logger.info(f"anonymized_text={new_text}")
        return {'text': new_text, 'placeholdersMap': placeholders}

    def restore(self, text: str, placeholders_map: Dict[str, str]):
        logger.debug(f"restore: input_text={text}")
        logger.debug(f"restore: placeholders_map={placeholders_map}")
        restored = text
        # Index original values by unique id suffix for robust matching
        unique_id_to_value: Dict[str, str] = {}
        for placeholder_token, original_value in placeholders_map.items():
            m = re.search(r"_(\d+)__$", placeholder_token)
            if m:
                unique_id_to_value[m.group(1)] = original_value

        # First, try exact replacements
        for placeholder_token, original_value in placeholders_map.items():
            if placeholder_token in restored:
                restored = restored.replace(placeholder_token, original_value)
        logger.debug(f"restore: after_exact={restored}")

        # Second, handle partial/altered tokens commonly produced by LLMs
        # (A) Original value followed by leaked id suffix like '...<orig>12345__' -> remove suffix
        for placeholder_token, original_value in placeholders_map.items():
            m = re.search(r"_(\d+)__$", placeholder_token)
            if not m:
                continue
            unique_id = m.group(1)
            pattern_a = re.escape(original_value) + re.escape(unique_id) + r"__"
            restored = re.sub(pattern_a, original_value, restored, flags=re.IGNORECASE)

        logger.debug(f"restore: after_suffix_fix={restored}")

        # (B) Placeholder variants in text: allow optional leading/trailing underscores to be missing
        # Match tokens like '__PII_..._<id>__', 'PII_..._<id>', '_PII_..._<id>__', etc.
        generic_pattern = re.compile(r"_?_{0,1}PII[\w-]*_(\d+)_?_{0,1}", re.IGNORECASE)

        def replace_generic(m: re.Match) -> str:
            uid = m.group(1)
            return unique_id_to_value.get(uid, m.group(0))

        restored = generic_pattern.sub(replace_generic, restored)
        logger.debug(f"restore: after_variant_fix={restored}")
        return restored
