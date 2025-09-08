#!/usr/bin/env python3
import argparse
import os
import sys
from pathlib import Path

import torch
from transformers import AutoTokenizer, AutoModelForTokenClassification

try:
    from onnxruntime.quantization import quantize_dynamic, QuantType
except Exception:
    quantize_dynamic = None
    QuantType = None

try:
    import onnx
    from onnxsim import simplify as onnx_simplify  # optional graph optimization
except Exception:
    onnx = None
    onnx_simplify = None


def export_onnx(model, tokenizer, out_path: Path, opset: int = 14):
    out_path.parent.mkdir(parents=True, exist_ok=True)
    model.eval()
    dummy = tokenizer("Hello world!", return_tensors="pt")
    with torch.no_grad():
        torch.onnx.export(
            model,
            (dummy["input_ids"], dummy["attention_mask"]),
            str(out_path),
            input_names=["input_ids", "attention_mask"],
            output_names=["logits"],
            dynamic_axes={
                "input_ids": {0: "batch", 1: "sequence"},
                "attention_mask": {0: "batch", 1: "sequence"},
                "logits": {0: "batch", 1: "sequence"},
            },
            opset_version=opset,
        )


def maybe_optimize_graph(onnx_path: Path, do_opt: bool) -> None:
    try:
        if not do_opt:
            return
        if onnx is None or onnx_simplify is None:
            print("[onnx] graph optimization not available (install onnx-simplifier)")
            return
        print(f"[onnx] simplifying graph: {onnx_path}")
        model = onnx.load(str(onnx_path))
        model_simpl, ok = onnx_simplify(model)
        if ok:
            onnx.save(model_simpl, str(onnx_path))
            print("[onnx] simplified ok")
        else:
            print("[onnx] simplify returned not-ok; kept original")
    except Exception as e:
        print(f"[onnx] simplifier failed: {e}; proceeding without simplification")


def maybe_infer_shapes(onnx_path: Path) -> None:
    try:
        if onnx is None:
            return
        print(f"[onnx] inferring shapes: {onnx_path}")
        model = onnx.load(str(onnx_path))
        inferred = onnx.shape_inference.infer_shapes(model)
        onnx.save(inferred, str(onnx_path))
        print("[onnx] shapes inferred")
    except Exception as e:
        print(f"[onnx] shape inference failed: {e}; continuing")


def maybe_quantize(src_onnx: Path, dst_onnx: Path, enable: bool) -> None:
    if not enable:
        return
    if dst_onnx.exists():
        try:
            if os.path.getsize(dst_onnx) > 1024:
                print(f"[quant] skip; exists: {dst_onnx}")
                return
            else:
                print(f"[quant] existing quantized file is too small; regenerating: {dst_onnx}")
        except Exception:
            pass
    if quantize_dynamic is None:
        print("[quant] onnxruntime quantization not available; skipping INT8")
        return
    print(f"[quant] quantizing {src_onnx} -> {dst_onnx}")
    # Focus on typical weight-bearing ops to avoid warnings on unsupported tensors
    op_types_to_quantize = ["MatMul", "Gemm"]
    # try:
    #     quantize_dynamic(
    #         model_input=str(src_onnx),
    #         model_output=str(dst_onnx),
    #         weight_type=QuantType.QInt8,
    #         per_channel=True,
    #         optimize_model=True,
    #         op_types_to_quantize=op_types_to_quantize,
    #     )
    # except TypeError:
    # Older onnxruntime doesn't support some kwargs; fallback to minimal call
    quantize_dynamic(
        model_input=str(src_onnx),
        model_output=str(dst_onnx),
        weight_type=QuantType.QInt8,
        # optimize_model=True,
    )


def main():
    ap = argparse.ArgumentParser(description="Export HF token-classification model to ONNX and optionally quantize/optimize")
    ap.add_argument("--model", help="HF repo id (e.g., gagan3012/bert-tiny-finetuned-ner) or local dir.")
    ap.add_argument("--out-dir", default="ner-models", help="Output base directory (default: ner-models)")
    ap.add_argument("--name", default=None, help="Subdir name under out-dir; defaults to repo id")
    ap.add_argument("--no-quant", action="store_true", help="Disable dynamic INT8 quantization")
    ap.add_argument("--opt", action="store_true", help="Apply ONNX graph optimization (simplifier)")
    ap.add_argument("--opset", type=int, default=14)
    args = ap.parse_args()

    if not args.model:
        ap.error("--model is required")

    repo_or_dir = args.model
    subdir = args.name or repo_or_dir
    base = Path(args.out_dir).resolve() / subdir
    # Ensure we export directly into the expected public models target
    onnx_dir = base / "onnx"
    onnx_dir.mkdir(parents=True, exist_ok=True)

    # Load model/tokenizer (supports local dir)
    print(f"[load] {repo_or_dir}")
    # Pass through HF env/proxy automatically; users can set HF_TOKEN/HF_ENDPOINT/HTTP(S)_PROXY
    tokenizer = AutoTokenizer.from_pretrained(repo_or_dir, token=os.environ.get("HF_TOKEN"))
    model = AutoModelForTokenClassification.from_pretrained(repo_or_dir, token=os.environ.get("HF_TOKEN"))

    # Ensure required tokenizer/config files are present alongside ONNX model for the browser demo
    # Prefer fast tokenizer.json if available; else copy vocab.txt
    try:
        tok_json = tokenizer.init_kwargs.get("tokenizer_file", None)
        vocab_file = getattr(tokenizer, "vocab_file", None)
        tokenizer_target_json = base / "tokenizer.json"
        tokenizer_target_vocab = base / "vocab.txt"
        if tok_json and os.path.exists(tok_json):
            from shutil import copyfile
            if not tokenizer_target_json.exists():
                copyfile(tok_json, tokenizer_target_json)
                print(f"[copy] tokenizer.json -> {tokenizer_target_json}")
        elif vocab_file and os.path.exists(vocab_file):
            from shutil import copyfile
            copyfile(vocab_file, tokenizer_target_vocab)
            print(f"[copy] vocab.txt -> {tokenizer_target_vocab}")
    except Exception:
        pass

    # Copy auxiliary files if they exist in cache
    try:
        from transformers.utils.hub import cached_file
        for fname in ["tokenizer.json", "vocab.txt", "tokenizer_config.json", "config.json", "special_tokens_map.json"]:
            try:
                src = cached_file(repo_or_dir, fname, token=os.environ.get("HF_TOKEN"))
                if src and os.path.exists(src):
                    from shutil import copyfile
                    dst = base / fname
                    copyfile(src, dst)
                    print(f"[copy] {fname} -> {dst}")
            except Exception:
                pass
    except Exception:
        pass

    # Export ONNX
    onnx_model = onnx_dir / "model.onnx"
    export_onnx(model, tokenizer, onnx_model, opset=args.opset)
    print(f"[onnx] exported: {onnx_model}")

    # Optional ONNX graph optimization
    maybe_optimize_graph(onnx_model, args.opt)
    # Pre-processing recommended by ORT: run shape inference to stabilize types and dims
    maybe_infer_shapes(onnx_model)

    # Quantize if enabled and not already present
    quant_model = onnx_dir / "model_quantized.onnx"
    maybe_quantize(onnx_model, quant_model, enable=(not args.no_quant))

    # Report sizes if present
    def size_mb(p: Path) -> float:
        try:
            return os.path.getsize(p) / 1024 / 1024
        except Exception:
            return 0.0

    print(f"[size] model.onnx={size_mb(onnx_model):.2f}MB; model_quantized.onnx={size_mb(quant_model):.2f}MB")
    # Extra sync: ensure file truly exists and is visible in listing (macOS FS issues workaround)
    try:
        os.sync()
    except Exception:
        pass
    try:
        listed = os.listdir(onnx_dir)
        print(f"[out] artifacts in: {base}, onnx_dir entries: {listed}")
    except Exception:
        print(f"[out] artifacts in: {base}")


if __name__ == "__main__":
    main()

