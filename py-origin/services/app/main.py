from fastapi import FastAPI, Header, HTTPException
from pydantic import BaseModel
from typing import Optional, Dict, Any, List, Union
from .one_aifw_api import OneAIFWAPI
from .aifw_utils import cleanup_monthly_logs
import os
import logging

logger = logging.getLogger(__name__)

app = FastAPI(title="OneAIFW Service", version="0.2.0")

api = OneAIFWAPI()
# HTTP API key for Authorization header; can be set via env AIFW_HTTP_API_KEY
API_KEY = os.environ.get("AIFW_HTTP_API_KEY") or None


class CallIn(BaseModel):
	text: str
	apiKeyFile: Optional[str] = None
	model: Optional[str] = None
	temperature: Optional[float] = 0.0


class MaskIn(BaseModel):
	text: str
	language: Optional[str] = None


class RestoreIn(BaseModel):
	text: str
	# maskMeta: base64 string of JSON(bytes) for placeholdersMap
	maskMeta: str


def parse_auth_header(auth: Optional[str]) -> Optional[str]:
    if not auth:
        return None
    s = auth.strip()
    if s.lower().startswith("bearer "):
        return s[7:].strip()
    return s


def check_api_key(authorization: Optional[str] = Header(None)):
    if not API_KEY:
        return True
    token = parse_auth_header(authorization)
    if token != API_KEY:
        logger.error(f"check_api_key: authorization: {authorization}, token: {token}, API_KEY: {API_KEY}, unauthorized error")
        raise HTTPException(status_code=401, detail="Unauthorized")
    return True


@app.get("/api/health")
async def health():
	return {"status": "ok"}


@app.post("/api/call")
async def api_call(inp: CallIn, authorization: Optional[str] = Header(None)):
	check_api_key(authorization)
	default_key_file = os.environ.get("AIFW_API_KEY_FILE")
	chosen_key_file = inp.apiKeyFile or default_key_file
	# Server-side monthly log cleanup based on env config
	base_log = os.environ.get("AIFW_LOG_FILE")
	try:
		months = int(os.environ.get("AIFW_LOG_MONTHS_TO_KEEP", "6"))
	except Exception:
		months = 6
	cleanup_monthly_logs(base_log, months)
	try:
		out = api.call(
			text=inp.text,
			api_key_file=chosen_key_file,
			model=inp.model,
			temperature=inp.temperature or 0.0,
		)
		return {"output": {"text": out}, "error": None}
	except Exception as e:
		logger.exception("/api/call failed")
		return {"output": None, "error": {"message": str(e), "code": None}}


@app.post("/api/mask_text")
async def api_mask_text(inp: MaskIn, authorization: Optional[str] = Header(None)):
	check_api_key(authorization)
	try:
		res = api.mask_text(text=inp.text, language=inp.language)
		return {"output": {"text": res["text"], "maskMeta": res["maskMeta"]}, "error": None}
	except Exception as e:
		logger.exception("/api/mask_text failed")
		return {"output": None, "error": {"message": str(e), "code": None}}


@app.post("/api/restore_text")
async def api_restore_text(inp: RestoreIn, authorization: Optional[str] = Header(None)):
	check_api_key(authorization)
	try:
		restored = api.restore_text(text=inp.text, mask_meta=inp.maskMeta)
		return {"output": {"text": restored}, "error": None}
	except Exception as e:
		logger.exception("/api/restore_text failed")
		return {"output": None, "error": {"message": str(e), "code": None}}


@app.post("/api/mask_text_batch")
async def api_mask_text_batch(inp_array: List[MaskIn], authorization: Optional[str] = Header(None)):
	check_api_key(authorization)
	try:
		res_array = []
		for inp in inp_array:
			res_array.append(api.mask_text(text=inp.text, language=inp.language))
		return {"output": res_array, "error": None}
	except Exception as e:
		logger.exception("/api/mask_text_batch failed")
		return {"output": None, "error": {"message": str(e), "code": None}}


@app.post("/api/restore_text_batch")
async def api_restore_text_batch(inp_array: List[RestoreIn], authorization: Optional[str] = Header(None)):
	check_api_key(authorization)
	try:
		restored_array = []
		for inp in inp_array:
			restored = api.restore_text(text=inp.text, mask_meta=inp.maskMeta)
			restored_array.append({"text": restored})
		return {"output": restored_array, "error": None}
	except Exception as e:
		logger.exception("/api/restore_text_batch failed")
		return {"output": None, "error": {"message": str(e), "code": None}}