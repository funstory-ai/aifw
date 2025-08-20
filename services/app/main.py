from fastapi import FastAPI, Header, HTTPException
from pydantic import BaseModel
from typing import Optional
from .one_aifw_api import OneAIFWAPI

app = FastAPI(title="OneAIFW Service", version="0.2.0")

api = OneAIFWAPI()
API_KEY = None  # set via env if desired


class CallIn(BaseModel):
	text: str
	apiKeyFile: Optional[str] = None
	model: Optional[str] = None
	temperature: Optional[float] = 0.0


def check_api_key(x_api_key: Optional[str] = Header(None)):
	if API_KEY is None:
		return True
	if x_api_key != API_KEY:
		raise HTTPException(status_code=401, detail="Unauthorized")
	return True


@app.get("/api/health")
async def health():
	return {"status": "ok"}


@app.post("/api/call")
async def api_call(inp: CallIn, x_api_key: Optional[str] = Header(None)):
	check_api_key(x_api_key)
	out = api.call(
		text=inp.text,
		api_key_file=inp.apiKeyFile,
		model=inp.model,
		temperature=inp.temperature or 0.0,
	)
	return {"text": out}
