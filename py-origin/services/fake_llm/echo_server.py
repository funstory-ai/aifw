from fastapi import FastAPI, Header, HTTPException
from pydantic import BaseModel, Field
from typing import List, Optional, Any, Dict
import time
import uuid


app = FastAPI(title="Fake Echo LLM (OpenAI-compatible)", version="0.1.0")


# ---- Schemas (minimal) ----
class ChatMessage(BaseModel):
    role: str
    content: str


class ChatCompletionsIn(BaseModel):
    model: Optional[str] = Field(default="echo-001")
    messages: List[ChatMessage]
    temperature: Optional[float] = 0.0


class CompletionsIn(BaseModel):
    model: Optional[str] = Field(default="echo-001")
    prompt: str
    temperature: Optional[float] = 0.0


def _check_auth(authorization: Optional[str]):
    # Accept any Bearer token; require header to be present for realism
    if not authorization or not authorization.lower().startswith("bearer "):
        # stay permissive; do not hard fail to simplify local usage
        return


@app.get("/v1/models")
def list_models(x_api_key: Optional[str] = Header(None), authorization: Optional[str] = Header(None)):
    _check_auth(authorization)
    return {
        "object": "list",
        "data": [
            {
                "id": "echo-001",
                "object": "model",
                "created": int(time.time()),
                "owned_by": "local",
            }
        ],
    }


@app.post("/v1/chat/completions")
def chat_completions(inp: ChatCompletionsIn, x_api_key: Optional[str] = Header(None), authorization: Optional[str] = Header(None)):
    _check_auth(authorization)
    # Echo last user content; fallback to concat
    last_user = next((m.content for m in reversed(inp.messages) if m.role == "user"), None)
    if last_user is None:
        last_user = "\n\n".join([m.content for m in inp.messages])
    resp_id = f"chatcmpl-{uuid.uuid4().hex[:12]}"
    now = int(time.time())
    return {
        "id": resp_id,
        "object": "chat.completion",
        "created": now,
        "model": inp.model or "echo-001",
        "choices": [
            {
                "index": 0,
                "message": {"role": "assistant", "content": last_user},
                "finish_reason": "stop",
            }
        ],
        "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
    }


@app.post("/v1/completions")
def completions(inp: CompletionsIn, x_api_key: Optional[str] = Header(None), authorization: Optional[str] = Header(None)):
    _check_auth(authorization)
    resp_id = f"cmpl-{uuid.uuid4().hex[:12]}"
    now = int(time.time())
    return {
        "id": resp_id,
        "object": "text_completion",
        "created": now,
        "model": inp.model or "echo-001",
        "choices": [
            {
                "index": 0,
                "text": inp.prompt,
                "finish_reason": "stop",
            }
        ],
        "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
    }


@app.get("/v1/health")
def health():
    return {"status": "ok"}


