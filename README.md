# OneAIFW - Local Presidio-based Reversible Anonymization Framework

This repository provides a local Presidio-based service (OneAIFW) with:
- FastAPI backend using `presidio-analyzer` and `presidio-anonymizer`
- Reversible translation-safe placeholders for anonymization
- Tkinter desktop UI client to call the service
- Browser extension (Chrome/Edge MV3) to anonymize selected text on web pages
- Dockerfile + docker-compose for easy local deployment

## Quickstart - Service
```bash
cd services/presidio_service
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
uvicorn app.main:app --host 127.0.0.1 --port 8000 --reload
```

Or with Docker:
```bash
cd services/presidio_service
docker build -t oneaifw-presidio-service .
docker run -p 8000:8000 -e API_KEY=changeme-please oneaifw-presidio-service
```

## UI
```bash
cd ui
pip install -r requirements.txt
python desktop_app.py
```

## Browser Extension
Load `browser_extension` as unpacked extension in Chrome/Edge developer mode.

## Notes
- To improve detection, install `en_core_web_sm` via `python -m spacy download en_core_web_sm` in the service venv.
- The anonymization uses placeholders that are robust to machine translation/LLM round-trips.
