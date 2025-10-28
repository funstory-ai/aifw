from fastapi import FastAPI, Header, HTTPException, Request
from fastapi.responses import Response, PlainTextResponse
from pydantic import BaseModel
from typing import Optional, Dict, Any, List, Union
from .one_aifw_api import OneAIFWAPI
from .aifw_utils import cleanup_monthly_logs
import os
import logging
import struct

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
	# Accept bytes array (list[int]) per requirement
	maskMeta: bytes


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
	out = api.call(
		text=inp.text,
		api_key_file=chosen_key_file,
		model=inp.model,
		temperature=inp.temperature or 0.0,
	)
	return {"text": out}


@app.post("/api/mask_text")
async def api_mask_text(inp: MaskIn, x_api_key: Optional[str] = Header(None)):
    check_api_key(x_api_key)
    res = api.mask_text(text=inp.text, language=inp.language)
    # Binary response: [u32_le text_len][text bytes][maskMeta bytes]
    masked_text = res["text"]
    meta_bytes = res["maskMeta"]
    if not isinstance(meta_bytes, (bytes, bytearray)):
        meta_bytes = bytes(meta_bytes)
    text_bytes = (masked_text or "").encode("utf-8")
    header = struct.pack('<I', len(text_bytes))
    payload = header + text_bytes + bytes(meta_bytes)
    return Response(content=payload, media_type='application/octet-stream')


@app.post("/api/restore_text")
async def api_restore_text(req: Request, x_api_key: Optional[str] = Header(None)):
    check_api_key(x_api_key)
    body = await req.body()
    if len(body) < 4:
        raise HTTPException(status_code=400, detail="invalid payload")
    (text_len,) = struct.unpack('<I', body[:4])
    if len(body) < 4 + text_len:
        raise HTTPException(status_code=400, detail="truncated payload")
    text_bytes = body[4:4+text_len]
    meta_bytes = body[4+text_len:]
    masked_text = text_bytes.decode('utf-8')
    restored = api.restore_text(text=masked_text, mask_meta=meta_bytes)
    return PlainTextResponse(content=restored, media_type='text/plain; charset=utf-8')
