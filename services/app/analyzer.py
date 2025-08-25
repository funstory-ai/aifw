from presidio_analyzer import AnalyzerEngine, PatternRecognizer
from presidio_analyzer import Pattern, RecognizerRegistry
from presidio_analyzer.nlp_engine import NlpEngineProvider
from typing import List, Dict, Any
from dataclasses import dataclass
import logging
import sys
from spacy.language import Language
from langdetect import detect as langdetect_detect
import re
import json
import os

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
        # Try larger models first if available, then fall back
        desired = {
            'en': ['en_core_web_sm'],
            'fr': ['fr_core_news_sm'],
            'de': ['de_core_news_sm'],
            'ko': ['ko_core_news_sm'],
            'ja': ['ja_core_news_sm'],
            'zh': ['zh_core_web_sm'],
            'xx': ['xx_ent_wiki_sm'],
        }
        models_cfg = []
        for lang_code, candidates in desired.items():
            chosen = None
            for name in candidates:
                try:
                    spacy.load(name)
                    chosen = name
                    break
                except Exception:
                    continue
            if chosen:
                models_cfg.append({'lang_code': lang_code, 'model_name': chosen})
        if not any(m['lang_code'] == 'en' for m in models_cfg):
            # Ensure at least English is present for Presidio internals
            models_cfg.append({'lang_code': 'en', 'model_name': 'en_core_web_sm'})
        logger.debug("SpaCy models configured: %s", models_cfg)
        return {'nlp_engine_name': 'spacy', 'models': models_cfg}
    except Exception as e:
        logger.warning('spaCy not available: %s', e)
        return {'nlp_engine_name': 'spacy', 'models': [{'lang_code': 'en', 'model_name': 'en_core_web_sm'}]}


def _build_per_language_patterns(lang: str) -> List[PatternRecognizer]:
    """Create language-bucketed pattern recognizers for language-agnostic PII.
    This ensures Presidio registry selects them when running with language=lang.
    """
    recognizers: List[PatternRecognizer] = []
    # Email (generic)
    email_pat = Pattern(name='Email', regex=r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', score=0.85)
    email_rec = PatternRecognizer(
        supported_entity='EMAIL_ADDRESS',
        patterns=[email_pat],
        context=['邮箱', '电子邮件', 'email', 'mail'],
        supported_language=lang,
    )
    recognizers.append(email_rec)
    # CN Phone (apply to all langs)
    cn_phone_pat = Pattern(name='CN Phone', regex=r'(?:\+?86[-\s]?)?(1[3-9]\d[-\s]?\d{4}[-\s]?\d{4})', score=0.86)
    cn_phone_rec = PatternRecognizer(
        supported_entity='PHONE_NUMBER',
        patterns=[cn_phone_pat],
        context=['电话', '手机', 'phone', 'tel', 'mobile', 'téléphone', 'numéro'],
        supported_language=lang,
    )
    recognizers.append(cn_phone_rec)
    # IPv4
    ipv4_pat = Pattern(name='IPv4', regex=r'\b(?:(?:25[0-5]|2[0-4]\d|[01]?\d\d?)\.){3}(?:25[0-5]|2[0-4]\d|[01]?\d\d?)\b', score=0.6)
    ipv4_rec = PatternRecognizer(
        supported_entity='IP_ADDRESS',
        patterns=[ipv4_pat],
        context=['IP', '地址', 'ip address'],
        supported_language=lang,
    )
    recognizers.append(ipv4_rec)
    # CN ID
    cnid_pat = Pattern(name='CN ID', regex=r'\b[1-9]\d{5}(19|20)\d{2}(0[1-9]|1[0-2])(0[1-9]|[12]\d|3[01])\d{3}[0-9Xx]\b', score=0.7)
    cnid_rec = PatternRecognizer(
        supported_entity='CN_ID',
        patterns=[cnid_pat],
        context=['身份证', 'ID'],
        supported_language=lang,
    )
    recognizers.append(cnid_rec)
    # FR Phone only for fr
    if lang == 'fr':
        fr_phone_pat = Pattern(name='FR Phone', regex=r'(?:\+33|0033|0)\s?[1-9](?:[\s\.-]?\d{2}){4}', score=0.75)
        fr_phone_rec = PatternRecognizer(
            supported_entity='PHONE_NUMBER',
            patterns=[fr_phone_pat],
            context=['téléphone', 'portable', 'mobile', 'numéro'],
            supported_language='fr',
        )
        recognizers.append(fr_phone_rec)
    return recognizers


def _log_recognizers(analyzer_engine, available_langs):
    # Log recognizers loaded per language
    try:
        for lang in sorted(available_langs):
            reg = analyzer_engine.registry
            # Try modern API first
            ents = None
            try:
                ents = reg.get_supported_entities(languages=[lang])
            except TypeError:
                try:
                    ents = reg.get_supported_entities(language=lang)
                except TypeError:
                    try:
                        ents = reg.get_supported_entities()
                    except Exception as e:
                        logger.debug('get_supported_entities failed for lang=%s: %s', lang, e)
            if not ents:
                ents = ['EMAIL_ADDRESS','PHONE_NUMBER','IP_ADDRESS','CN_ID','PERSON','ORGANIZATION','DATE_TIME']
            ent_to_recs = {}
            for ent in ents:
                try:
                    try:
                        recs = reg.get_recognizers(language=lang, entities=[ent])
                    except TypeError:
                        recs = reg.get_recognizers(languages=[lang], entities=[ent])
                    names = []
                    for rec in recs:
                        name = getattr(rec, 'name', rec.__class__.__name__)
                        names.append(name)
                    ent_to_recs[ent] = sorted(set(names))
                except Exception as e:
                    ent_to_recs[ent] = [f'error:{e}']
            logger.debug('Registry entities for lang=%s: %s', lang, ents)
            logger.debug('Registry recognizers map for lang=%s: %s', lang, ent_to_recs)
    except Exception as e:
        logger.warning('Failed to enumerate recognizers: %s', e)


class AnalyzerWrapper:
    def __init__(self):
        cfg = _try_spacy_configuration()
        logger.debug('AnalyzerWrapper: spaCy configuration: %s', cfg)
        provider = NlpEngineProvider(nlp_configuration=cfg)
        nlp_engine = provider.create_engine()
        logger.debug('AnalyzerWrapper: nlp_engine: %s', nlp_engine)
        registry = RecognizerRegistry()
        registry.load_predefined_recognizers(nlp_engine=nlp_engine)
        self.engine = AnalyzerEngine(nlp_engine=nlp_engine, registry=registry)
        # Track available languages in the NLP engine robustly
        try:
            if hasattr(nlp_engine, 'nlps') and hasattr(nlp_engine.nlps, 'keys'):
                self.available_langs = set(list(nlp_engine.nlps.keys()))
            elif hasattr(nlp_engine, 'languages'):
                self.available_langs = set(nlp_engine.languages)
            elif hasattr(nlp_engine, 'get_supported_languages'):
                self.available_langs = set(nlp_engine.get_supported_languages())
            else:
                self.available_langs = set([m['lang_code'] for m in cfg.get('models', [])])
            logger.debug('AnalyzerWrapper: available_langs: %s', self.available_langs)
        except Exception as e:
            self.available_langs = {'en'}
            logger.warning('AnalyzerWrapper: failed to get available_langs: %s', e)
        # Add per-language custom recognizers so they are selected in each language bucket
        for lang in sorted(self.available_langs):
            for rec in _build_per_language_patterns(lang):
                self.engine.registry.add_recognizer(rec)
        # Log recognizers per language
        # _log_recognizers(self.engine, self.available_langs)
        # Load filtering/whitelist config
        self.entity_filters, self.entity_whitelist = self._load_entity_configs()

    def _load_entity_configs(self):
        # Look for config at services/app/presidio_filters.json
        try:
            base_dir = os.path.dirname(os.path.abspath(__file__))
            cfg_path = os.path.join(base_dir, 'presidio_filters.json')
            if os.path.exists(cfg_path):
                with open(cfg_path, 'r', encoding='utf-8') as f:
                    data = json.load(f)
                logger.debug("Loaded entity filters config from %s: %s", cfg_path, data)
                return data.get('entity_filters', {}), data.get('entity_whitelist', {})
            else:
                logger.warning("Entity filters config not found at %s; using defaults.", cfg_path)
        except Exception as e:
            logger.warning('Failed to load entity filters: %s', e)
        return {}, {}

    # If there's an instruction prefix (e.g., Chinese/English prompt) followed by ':' or '：',
    # detect on the substring after the first colon to better reflect the content language.
    def _instruction_prefix_end(self, t: str) -> int:
        idx = -1
        for ch in [':', '：']:
            j = t.find(ch)
            if j != -1 and (idx == -1 or j < idx):
                idx = j
        if 0 < idx < 80:
            prefix = t[:idx]
            if any(k in prefix for k in ['翻译', '如下', 'translate', 'following']):
                return idx + 1
        return -1

    def analyze(self, text: str, language: str = 'en') -> List[EntitySpan]:
        # Choose best available spaCy language; default to en
        lang = (language or 'en').lower()
        available = getattr(self, 'available_langs', {'en'})
        engine_lang = lang if lang in available else 'en'
        logger.debug("Analyzer.analyze: input_lang=%s engine_lang=%s available=%s", language, engine_lang, available)

        try:
            # Run full Presidio pass
            pres_results = self.engine.analyze(text=text, language=engine_lang, entities=None)
        except Exception as e:
            logger.debug("Presidio analyze failed: %s", e)
            pres_results = []
        logger.debug("Analyzer.analyze pres_results=%s", [(r.entity_type, r.start, r.end, getattr(r,'score',None)) for r in pres_results])
        # Drop any entities detected in instruction prefix (before first colon with keywords)
        prefix_end = self._instruction_prefix_end(text)
        if prefix_end >= 0:
            before = len(pres_results)
            pres_results = [r for r in pres_results if r.end > prefix_end]
            logger.debug("Dropped %s entities in instruction prefix [0:%s]", before - len(pres_results), prefix_end)
        # Step 1: filter low-confidence per JSON config
        filtered_results = self._apply_entity_filters(pres_results, engine_lang)
        logger.debug("After min_score filter: %s", [(r.entity_type, r.start, r.end, getattr(r,'score',None)) for r in filtered_results])

        # Step 2: (regex fallback disabled) convert Presidio results to EntitySpan only
        merged: List[EntitySpan] = [
            EntitySpan(r.entity_type, r.start, r.end, getattr(r, 'score', 0.0), text[r.start:r.end])
            for r in filtered_results
        ]
        logger.debug("Regex fallback disabled; merged from pres_results only: %s", [(r.entity_type, r.start, r.end) for r in merged])

        # Step 3: apply whitelist
        final = self._apply_entity_whitelist(merged, engine_lang)
        logger.debug("After whitelist filter: %s", [(r.entity_type, r.start, r.end) for r in final])
        return final

    def _regex_fallback_spans(self, text: str) -> List[EntitySpan]:
        """Build language-agnostic regex spans (disabled by default)."""
        spans: List[EntitySpan] = []
        # Email regex
        for m in re.finditer(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}", text):
            spans.append(EntitySpan('EMAIL_ADDRESS', m.start(), m.end(), 0.95, text[m.start():m.end()]))
        # Chinese mobile (11 digits)
        for m in re.finditer(r"(?:\+?86[-\s]?)?(1[3-9]\d[-\s]?\d{4}[-\s]?\d{4})", text):
            spans.append(EntitySpan('PHONE_NUMBER', m.start(), m.end(), 0.9, text[m.start():m.end()]))
        # IPv4
        for m in re.finditer(r"\b(?:(?:25[0-5]|2[0-4]\d|[01]?\d\d?)\.){3}(?:25[0-5]|2[0-4]\d|[01]?\d\d?)\b", text):
            spans.append(EntitySpan('IP_ADDRESS', m.start(), m.end(), 0.9, text[m.start():m.end()]))
        # CN_ID
        for m in re.finditer(r"\b[1-9]\d{5}(19|20)\d{2}(0[1-9]|1[0-2])(0[1-9]|[12]\d|3[01])\d{3}[0-9Xx]\b", text):
            spans.append(EntitySpan('CN_ID', m.start(), m.end(), 0.9, text[m.start():m.end()]))
        return spans

    def _apply_entity_filters(self, results, lang: str):
        if not results:
            return results
        filters_for_lang = self.entity_filters.get(lang, {})
        filters_for_all = self.entity_filters.get('all', {})
        logger.debug("Applying entity filters for lang=%s; lang_filters=%s; all_filters=%s", lang, filters_for_lang, filters_for_all)
        def should_keep(r):
            cfg = filters_for_lang.get(r.entity_type) or filters_for_all.get(r.entity_type)
            if not cfg:
                # Support wildcard '*' default in either lang or all
                cfg = filters_for_lang.get('*') or filters_for_all.get('*')
            if not cfg:
                logger.debug("Keep entity (no filter): %s score=%s", r.entity_type, getattr(r,'score',None))
                return True
            # Support both boolean drop and threshold
            min_score = cfg.get('min_score')
            drop = cfg.get('drop', False)
            if drop:
                # If explicit drop with optional threshold
                if min_score is None:
                    logger.debug("Drop entity by config (drop=true): %s", r.entity_type)
                    return False
                keep = getattr(r, 'score', 0.0) >= float(min_score)
                logger.debug("%s entity by drop+threshold: %s score=%s min=%s", "Keep" if keep else "Drop", r.entity_type, getattr(r,'score',None), min_score)
                return keep
            if min_score is not None:
                keep = getattr(r, 'score', 0.0) >= float(min_score)
                logger.debug("%s entity by threshold: %s score=%s min=%s", "Keep" if keep else "Drop", r.entity_type, getattr(r,'score',None), min_score)
                return keep
            return True
        filtered = [r for r in results if should_keep(r)]
        logger.debug("Filtered entities: %s", [(r.entity_type, r.start, r.end, getattr(r,'score',None)) for r in filtered])
        return filtered

    def _apply_entity_whitelist(self, results, lang: str):
        if not results:
            return results
        wl_lang = self.entity_whitelist.get(lang)
        wl_all = self.entity_whitelist.get('all')
        if not wl_lang and not wl_all:
            logger.debug("Whitelist not configured; skipping whitelist filter.")
            return results
        allowed = set()
        if isinstance(wl_all, list):
            allowed.update(wl_all)
        if isinstance(wl_lang, list):
            allowed.update(wl_lang)
        if not allowed:
            logger.debug("Whitelist empty after merge; skipping whitelist filter.")
            return results
        kept = [r for r in results if r.entity_type in allowed]
        logger.debug("Whitelist allowed=%s; kept=%s", allowed, [(r.entity_type, r.start, r.end) for r in kept])
        return kept

    def detect_language(self, text: str) -> str:
        # Prefer lightweight detector to avoid running full spaCy pipeline
        if not text or not text.strip():
            return 'en'

        def _normalize_lang(code: str) -> str:
            code = (code or '').lower()
            if code.startswith('zh'):
                return 'zh'
            return code or 'en'

        # Extract candidate text after instruction prefix
        candidate = text[self._instruction_prefix_end(text):]

        # Heuristic based on character class counts
        cjk_count = len(re.findall(r'[\u4e00-\u9fff]', candidate))
        latin_count = len(re.findall(r'[A-Za-z]', candidate))
        signal = cjk_count + latin_count
        if signal >= 10 and (cjk_count > 0 and latin_count > 0):
            c_ratio = cjk_count / signal
            l_ratio = latin_count / signal
            if l_ratio >= 0.8:
                logger.debug("Language detect heuristic: latin-dominant -> en")
                return 'en'
            if c_ratio >= 0.8:
                logger.debug("Language detect heuristic: CJK-dominant -> zh")
                return 'zh'
            # Otherwise do not force 'en' for any latin-dominant text; allow detector to choose (fr/es/...) below

        try:
            code = langdetect_detect(candidate)
            norm = _normalize_lang(code)
            logger.debug("Language detect via langdetect: raw=%s normalized=%s candidate_sample=%s", code, norm, candidate[:80])
            return norm
        except Exception:
            return 'en'
