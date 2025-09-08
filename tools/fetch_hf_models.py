#!/usr/bin/env python3
import argparse
import os
import sys
from pathlib import Path

try:
    from huggingface_hub import hf_hub_download
except Exception as e:
    print("Error: huggingface_hub is required. Install with: pip install huggingface_hub", file=sys.stderr)
    raise

CANDIDATE_FILES = [
    # tokenizer (fast preferred, fallback vocab)
    "tokenizer.json",
    "vocab.txt",
    # extra helper
    "tokenizer_config.json",
    # config
    "config.json",
    # ONNX (quantized preferred)
    os.path.join("onnx", "model_quantized.onnx"),
    os.path.join("onnx", "model.onnx"),
]


def download_one(repo_id: str, filename: str, out_dir: Path, token: str | None) -> bool:
    dest = out_dir / filename
    dest.parent.mkdir(parents=True, exist_ok=True)
    try:
        local = hf_hub_download(repo_id=repo_id, filename=filename, token=token, local_dir=str(out_dir), local_dir_use_symlinks=False)
        # hf_hub_download already places file at local_dir/filename; ensure exists
        return os.path.exists(local)
    except Exception as e:
        # Not fatal; just report
        print(f"[fetch] skip {repo_id}/{filename}: {e}")
        return False


def main():
    ap = argparse.ArgumentParser(description="Fetch HF model artifacts (tokenizer/config/ONNX) to local dir")
    ap.add_argument("models", nargs="+", help="HF model repo ids, e.g. Xenova/bert-base-NER")
    ap.add_argument("--out-dir", default="ner-models", help="Output directory (default: ner-models)")
    ap.add_argument("--hf-token", default=os.environ.get("HF_TOKEN"), help="HF auth token for private models (or set HF_TOKEN)")
    args = ap.parse_args()

    base = Path(args.out_dir).resolve()
    base.mkdir(parents=True, exist_ok=True)

    for mid in args.models:
        print(f"[fetch] preparing: {mid}")
        out = base / mid
        for fname in CANDIDATE_FILES:
            download_one(mid, fname, out, args.hf_token)

    print(f"[fetch] done. Files stored under: {base}")


if __name__ == "__main__":
    main()
