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
API_KEY = None  # set via env if desired


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
async def api_mask_text(inp: MaskIn, x_api_key: Optional[str] = Header(None)):
	check_api_key(x_api_key)
	try:
		res = api.mask_text(text=inp.text, language=inp.language)
		return {"output": {"text": res["text"], "maskMeta": res["maskMeta"]}, "error": None}
	except Exception as e:
		logger.exception("/api/mask_text failed")
		return {"output": None, "error": {"message": str(e), "code": None}}


@app.post("/api/restore_text")
async def api_restore_text(inp: RestoreIn, x_api_key: Optional[str] = Header(None)):
	check_api_key(x_api_key)
	try:
		restored = api.restore_text(text=inp.text, mask_meta=inp.maskMeta)
		return {"output": {"text": restored}, "error": None}
	except Exception as e:
		logger.exception("/api/restore_text failed")
		return {"output": None, "error": {"message": str(e), "code": None}}


@app.post("/api/mask_text_batch")
async def api_mask_text_batch(inp_array: List[MaskIn], x_api_key: Optional[str] = Header(None)):
	check_api_key(x_api_key)
	try:
		res_array = []
		for inp in inp_array:
			res_array.append(api.mask_text(text=inp.text, language=inp.language))
		return {"output": res_array, "error": None}
	except Exception as e:
		logger.exception("/api/mask_text_batch failed")
		return {"output": None, "error": {"message": str(e), "code": None}}


@app.post("/api/restore_text_batch")
async def api_restore_text_batch(inp_array: List[RestoreIn], x_api_key: Optional[str] = Header(None)):
	check_api_key(x_api_key)
	try:
		restored_array = []
		for inp in inp_array:
			restored = api.restore_text(text=inp.text, mask_meta=inp.maskMeta)
			restored_array.append({"text": restored})
		return {"output": restored_array, "error": None}
	except Exception as e:
		logger.exception("/api/restore_text_batch failed")
		return {"output": None, "error": {"message": str(e), "code": None}}