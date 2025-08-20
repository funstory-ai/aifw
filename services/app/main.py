from fastapi import FastAPI, Header, HTTPException
from pydantic import BaseModel
from typing import Dict, Any, Optional
from .analyzer import AnalyzerWrapper
from .anonymizer import AnonymizerWrapper

app = FastAPI(title="OneAIFW Presidio Service", version="0.1.0")

# Instantiate (will load spaCy model if available; otherwise fall back)
analyzer = AnalyzerWrapper()
anonymizer = AnonymizerWrapper(analyzer.engine)

API_KEY = None  # set via environment variable in Docker or runtime if desired


class AnalyzeIn(BaseModel):
    text: str
    language: Optional[str] = "en"


class AnonymizeIn(BaseModel):
    text: str
    language: Optional[str] = "en"
    operators: Optional[Dict[str, Dict[str, Any]]] = None


class RestoreIn(BaseModel):
    text: str
    placeholdersMap: Dict[str, str]


def check_api_key(x_api_key: Optional[str] = Header(None)):
    if API_KEY is None:
        return True
    if x_api_key != API_KEY:
        raise HTTPException(status_code=401, detail="Unauthorized")
    return True


@app.get("/api/health")
def health():
    return {"status": "ok"}


@app.post("/api/analyze")
def api_analyze(inp: AnalyzeIn, x_api_key: Optional[str] = Header(None)):
    check_api_key(x_api_key)
    items = analyzer.analyze(inp.text, language=inp.language)
    return {"items": [i.__dict__ for i in items]}


@app.post("/api/anonymize")
def api_anonymize(inp: AnonymizeIn, x_api_key: Optional[str] = Header(None)):
    check_api_key(x_api_key)
    res = anonymizer.anonymize(inp.text, operators=inp.operators, language=inp.language)
    return res


@app.post("/api/restore")
def api_restore(inp: RestoreIn, x_api_key: Optional[str] = Header(None)):
    check_api_key(x_api_key)
    restored = anonymizer.restore(inp.text, inp.placeholdersMap)
    return {"text": restored}
