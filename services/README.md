# OneAIFW - Presidio Service

This directory contains the Presidio-based local service used by the OneAIFW project.

## Quickstart (local)
Create venv, install, and run with uvicorn:
```bash
cd services/presidio_service
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
uvicorn app.main:app --host 127.0.0.1 --port 8000 --reload
```

## Docker
```bash
cd services/presidio_service
docker build -t oneaifw-presidio-service .
docker run -p 8000:8000 -e API_KEY=changeme-please oneaifw-presidio-service
# or use docker-compose up
```

## Endpoints
- GET /api/health
- POST /api/analyze -> { items: [...] }
- POST /api/anonymize -> { text, placeholdersMap }
- POST /api/restore -> { text }

Notes:
- The service attempts to load spaCy `en_core_web_sm` if available, otherwise a blank spaCy model is used.
- Placeholders are translation-safe tokens used for reversible anonymization.
