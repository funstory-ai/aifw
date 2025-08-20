from presidio_analyzer import AnalyzerEngine, PatternRecognizer
from presidio_analyzer import Pattern, RecognizerRegistry
from presidio_analyzer.nlp_engine import NlpEngineProvider
from typing import List
from dataclasses import dataclass
import logging
from spacy.language import Language
from langdetect import detect as langdetect_detect
import re

logger = logging.getLogger(__name__)


@dataclass
class EntitySpan:
    entity_type: str
    start: int
    end: int
    score: float
    text: str


def _try_spacy_configuration():
    try:
        import spacy
        try:
            spacy.load('en_core_web_sm')
            model = 'en_core_web_sm'
        except Exception:
            # Model not installed. We'll still configure for 'en_core_web_sm'
            # so the error clearly indicates the correct model name.
            model = 'en_core_web_sm'
        return {'nlp_engine_name': 'spacy',
                'models': [{'lang_code': 'en', 'model_name': model}]}
    except Exception as e:
        logger.warning('spaCy not available: %s', e)
        # spaCy itself unavailable: keep config consistent to encourage installation
        return {'nlp_engine_name': 'spacy',
                'models': [{'lang_code': 'en', 'model_name': 'en_core_web_sm'}]}


def _custom_recognizers():
    patterns = []
    phone_pattern = Pattern(name='CN Phone', regex=r'(?:\+?86[-\s]?)?(1[3-9]\d[-\s]?\d{4}[-\s]?\d{4})', score=0.6)
    patterns.append(PatternRecognizer(supported_entity='PHONE_NUMBER', patterns=[phone_pattern], context=['电话', '手机', 'phone']))
    email_pattern = Pattern(name='Email', regex=r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', score=0.7)
    patterns.append(PatternRecognizer(supported_entity='EMAIL_ADDRESS', patterns=[email_pattern], context=['邮箱', 'email']))
    cnid_pattern = Pattern(name='CN ID', regex=r'\b[1-9]\d{5}(19|20)\d{2}(0[1-9]|1[0-2])(0[1-9]|[12]\d|3[01])\d{3}[0-9Xx]\b', score=0.7)
    patterns.append(PatternRecognizer(supported_entity='CN_ID', patterns=[cnid_pattern], context=['身份证', 'ID']))
    ipv4_pattern = Pattern(name='IPv4', regex=r'\b(?:(?:25[0-5]|2[0-4]\d|[01]?\d\d?)\.){3}(?:25[0-5]|2[0-4]\d|[01]?\d\d?)\b', score=0.6)
    patterns.append(PatternRecognizer(supported_entity='IP_ADDRESS', patterns=[ipv4_pattern], context=['IP', '地址']))
    return patterns


class AnalyzerWrapper:
    def __init__(self):
        cfg = _try_spacy_configuration()
        provider = NlpEngineProvider(nlp_configuration=cfg)
        nlp_engine = provider.create_engine()
        registry = RecognizerRegistry()
        registry.load_predefined_recognizers(nlp_engine=nlp_engine)
        for r in _custom_recognizers():
            registry.add_recognizer(r)
        self.engine = AnalyzerEngine(nlp_engine=nlp_engine, registry=registry)
        # Keep a reference to spaCy model (optional), but prefer lightweight detector
        try:
            self._spacy = nlp_engine.nlps.get('en')
        except Exception:
            self._spacy = None

    def analyze(self, text: str, language: str = 'en') -> List[EntitySpan]:
        results = self.engine.analyze(text=text, language=language)
        return [EntitySpan(r.entity_type, r.start, r.end, r.score,
                           text[r.start:r.end])
                for r in results]

    def detect_language(self, text: str) -> str:
        # Prefer lightweight detector to avoid running full spaCy pipeline
        if not text or not text.strip():
            return 'en'

        def _normalize_lang(code: str) -> str:
            code = (code or '').lower()
            if code.startswith('zh'):
                return 'zh'
            return code or 'en'

        def _extract_candidate(t: str) -> str:
            # If there's an instruction prefix (e.g., Chinese/English prompt) followed by ':' or '：',
            # detect on the substring after the first colon to better reflect the content language.
            idx = -1
            for ch in [':', '：']:
                j = t.find(ch)
                if j != -1 and (idx == -1 or j < idx):
                    idx = j
            if 0 < idx < 80:
                prefix = t[:idx]
                if any(k in prefix for k in ['翻译', '如下', '请', '将', 'translate', 'following']):
                    return t[idx+1:].strip()
            return t

        candidate = _extract_candidate(text)

        # Heuristic based on character class counts
        cjk_count = len(re.findall(r'[\u4e00-\u9fff]', candidate))
        latin_count = len(re.findall(r'[A-Za-z]', candidate))
        signal = cjk_count + latin_count
        if signal >= 10 and (cjk_count > 0 and latin_count > 0):
            c_ratio = cjk_count / signal
            l_ratio = latin_count / signal
            if l_ratio >= 0.6:
                return 'en'
            if c_ratio >= 0.6:
                return 'zh'
            # If mixed without clear dominance, fall back to detector on candidate

        try:
            code = langdetect_detect(candidate)
            return _normalize_lang(code)
        except Exception:
            return 'en'
