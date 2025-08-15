from presidio_anonymizer import AnonymizerEngine
from presidio_analyzer import RecognizerResult
from presidio_anonymizer.entities import OperatorConfig
from typing import List, Dict, Any, Optional
from dataclasses import dataclass
import uuid

@dataclass
class AnonymizeResult:
    text: str
    placeholdersMap: Dict[str, str]

class AnonymizerWrapper:
    def __init__(self, analyzer_engine):
        # Accept AnalyzerEngine instance; we'll use Presidio's Anonymizer for operators,
        # but also provide reversible placeholder flow.
        self.anonymizer = AnonymizerEngine()
        self.analyzer = analyzer_engine

    def anonymize(self, text: str, operators: Optional[Dict[str, Dict[str, Any]]] = None, language: str = 'en'):
        # Run analysis to get spans
        results: List[RecognizerResult] = self.analyzer.analyze(text=text, language=language)
        # Build placeholders map and replace from end
        placeholders = {}
        new_text = text
        for r in sorted(results, key=lambda x: x.start, reverse=True):
            placeholder = f"__PII_{r.entity_type}_{uuid.uuid4().hex[:8]}__"
            placeholders[placeholder] = text[r.start:r.end]
            new_text = new_text[:r.start] + placeholder + new_text[r.end:]
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
        return {'text': new_text, 'placeholdersMap': placeholders}

    def restore(self, text: str, placeholders_map: Dict[str, str]):
        restored = text
        for k, v in placeholders_map.items():
            restored = restored.replace(k, v)
        return restored
