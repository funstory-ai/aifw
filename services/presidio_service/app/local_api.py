from typing import Dict, Any, Optional, List

from .analyzer import AnalyzerWrapper, EntitySpan
from .anonymizer import AnonymizerWrapper


class OneAIFWLocalAPI:
    """In-process local API for anonymization and restoration.

    This avoids HTTP and can be imported by UI/CLI directly.
    Heavy Presidio engines are initialized once and reused.
    """

    def __init__(self):
        self._analyzer_wrapper = AnalyzerWrapper()
        self._anonymizer_wrapper = AnonymizerWrapper(self._analyzer_wrapper.engine)

    def analyze(self, text: str, language: str = "en") -> List[EntitySpan]:
        return self._analyzer_wrapper.analyze(text=text, language=language)

    def anonymize(
        self,
        text: str,
        operators: Optional[Dict[str, Dict[str, Any]]] = None,
        language: str = "en",
    ) -> Dict[str, Any]:
        return self._anonymizer_wrapper.anonymize(
            text=text, operators=operators, language=language
        )

    def restore(self, text: str, placeholders_map: Dict[str, str]) -> str:
        return self._anonymizer_wrapper.restore(text=text, placeholders_map=placeholders_map)


# Singleton instance to be shared across imports
api = OneAIFWLocalAPI()


# Convenience module-level functions
def analyze(text: str, language: str = "en") -> List[EntitySpan]:
    return api.analyze(text=text, language=language)


def anonymize(
    text: str,
    operators: Optional[Dict[str, Dict[str, Any]]] = None,
    language: str = "en",
) -> Dict[str, Any]:
    return api.anonymize(text=text, operators=operators, language=language)


def restore(text: str, placeholders_map: Dict[str, str]) -> str:
    return api.restore(text=text, placeholders_map=placeholders_map)


