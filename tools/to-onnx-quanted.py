#!/usr/bin/env python3
import argparse
import os
import sys
from pathlib import Path

import torch
from transformers import AutoTokenizer, AutoConfig, AutoModelForTokenClassification, AutoModelForSequenceClassification
import json

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

def ensure_fast_tokenizer(repo_or_dir: str, target_dir: Path, local_only: bool) -> bool:
    try:
        target_dir.mkdir(parents=True, exist_ok=True)
        tok = AutoTokenizer.from_pretrained(
            repo_or_dir,
            use_fast=True,
            token=os.environ.get("HF_TOKEN"),
            local_files_only=local_only,
        )
        tok.save_pretrained(target_dir.as_posix())
        print(f"[tok] saved fast tokenizer to {target_dir}")
        return True
    except Exception as e:
        print(f"[tok] fast load/save failed: {e}")
        return False


def try_build_fast_tokenizer_fallback(repo_or_dir: str, target_dir: Path, tokenizer, local_dir: Path | None) -> bool:
    try:
        tokenizer_target_json = target_dir / "tokenizer.json"
        tokenizer_target_vocab = target_dir / "vocab.txt"
        tokenizer_target_cfg = target_dir / "tokenizer_config.json"

        # Copy vocab.txt if available via slow tokenizer or local dir
        vocab_file = getattr(tokenizer, "vocab_file", None)
        if vocab_file and os.path.exists(vocab_file):
            from shutil import copyfile
            copyfile(vocab_file, tokenizer_target_vocab)
            print(f"[copy] vocab.txt -> {tokenizer_target_vocab}")
        elif local_dir and (local_dir / "vocab.txt").exists():
            from shutil import copyfile
            copyfile(local_dir / "vocab.txt", tokenizer_target_vocab)
            print(f"[copy] vocab.txt -> {tokenizer_target_vocab}")

        # Try to locate tokenizer_config.json locally first; else fetch from hub
        try:
            if local_dir and (local_dir / "tokenizer_config.json").exists():
                from shutil import copyfile
                copyfile(local_dir / "tokenizer_config.json", tokenizer_target_cfg)
                print(f"[copy] tokenizer_config.json -> {tokenizer_target_cfg}")
            else:
                from transformers.utils.hub import cached_file
                src_cfg = cached_file(repo_or_dir, "tokenizer_config.json", token=os.environ.get("HF_TOKEN"))
                if src_cfg and os.path.exists(src_cfg):
                    from shutil import copyfile
                    copyfile(src_cfg, tokenizer_target_cfg)
                    print(f"[copy] tokenizer_config.json -> {tokenizer_target_cfg}")
        except Exception:
            pass

        # Detect lowercase from config
        do_lower_case = False
        try:
            if tokenizer_target_cfg.exists():
                with open(tokenizer_target_cfg, "r", encoding="utf-8") as f:
                    tcfg = json.load(f)
                    do_lower_case = bool(tcfg.get("do_lower_case", False))
        except Exception:
            pass
        try:
            cfg = AutoConfig.from_pretrained(repo_or_dir, token=os.environ.get("HF_TOKEN"), local_files_only=bool(local_dir))
            do_lower_case = bool(getattr(cfg, "do_lower_case", do_lower_case))
        except Exception:
            pass

        # Load special tokens if present
        special_map = {}
        try:
            if local_dir and (local_dir / "special_tokens_map.json").exists():
                with open(local_dir / "special_tokens_map.json", "r", encoding="utf-8") as f:
                    special_map = json.load(f) or {}
            else:
                from transformers.utils.hub import cached_file
                stm = cached_file(repo_or_dir, "special_tokens_map.json", token=os.environ.get("HF_TOKEN"))
                if stm and os.path.exists(stm):
                    with open(stm, "r", encoding="utf-8") as f:
                        special_map = json.load(f) or {}
        except Exception:
            special_map = {}

        # Build fast WordPiece tokenizer via tokenizers
        from tokenizers import Tokenizer
        from tokenizers.models import WordPiece
        from tokenizers.normalizers import BertNormalizer
        from tokenizers.pre_tokenizers import BertPreTokenizer
        from tokenizers.processors import TemplateProcessing

        if not tokenizer_target_vocab.exists():
            print("[tok] missing vocab.txt; cannot build fast tokenizer fallback")
            return False

        try:
            model_wp = WordPiece.from_file(tokenizer_target_vocab.as_posix(), unk_token=special_map.get("unk_token", "[UNK]"))
        except Exception:
            vocab_dict = getattr(tokenizer, "get_vocab", lambda: {})()
            model_wp = WordPiece(vocab=vocab_dict, unk_token=special_map.get("unk_token", "[UNK]"))

        tok = Tokenizer(model_wp)
        tok.normalizer = BertNormalizer(
            clean_text=True,
            handle_chinese_chars=True,
            lowercase=do_lower_case,
            strip_accents=None if do_lower_case else False,
        )
        tok.pre_tokenizer = BertPreTokenizer()

        cls = special_map.get("cls_token", "[CLS]")
        sep = special_map.get("sep_token", "[SEP]")
        vocab_now = tok.get_vocab()
        tok.post_processor = TemplateProcessing(
            single=f"{cls} $A {sep}",
            pair=f"{cls} $A {sep} $B {sep}",
            special_tokens=[(cls, vocab_now.get(cls, 101)), (sep, vocab_now.get(sep, 102))],
        )

        tok.save(tokenizer_target_json.as_posix())
        print(f"[tok] built fast tokenizer.json -> {tokenizer_target_json}")
        return True
    except Exception as e:
        print(f"[tok] failed to build fast tokenizer.json: {e}")
        return False


def fix_tokenizer_config_fast(target_dir: Path) -> None:
    cfg_path = target_dir / "tokenizer_config.json"
    try:
        if not cfg_path.exists():
            return
        with open(cfg_path, "r", encoding="utf-8") as f:
            data = json.load(f)
        klass = str(data.get("tokenizer_class", ""))
        mapping = {
            "BertTokenizer": "BertTokenizerFast",
            "DistilBertTokenizer": "DistilBertTokenizerFast",
            "RobertaTokenizer": "RobertaTokenizerFast",
            "AlbertTokenizer": "AlbertTokenizerFast",
        }
        new_klass = mapping.get(klass)
        if new_klass:
            data["tokenizer_class"] = new_klass
            with open(cfg_path, "w", encoding="utf-8") as f:
                json.dump(data, f, ensure_ascii=False, indent=2)
            print(f"[tok] rewrote tokenizer_class -> {new_klass} in {cfg_path}")
    except Exception as e:
        print(f"[tok] fix_tokenizer_config_fast failed: {e}")

def main():
    ap = argparse.ArgumentParser(description="Export HF model to ONNX and optionally quantize/optimize")
    ap.add_argument("--model", help="HF repo id (e.g., gagan3012/bert-tiny-finetuned-ner) or local dir.")
    ap.add_argument("--out-dir", default="ner-models", help="Output base directory (default: ner-models)")
    ap.add_argument("--name", default=None, help="Subdir name under out-dir; defaults to repo id or local folder name")
    ap.add_argument("--no-quant", action="store_true", help="Disable dynamic INT8 quantization")
    ap.add_argument("--task", choices=["token-classification", "sequence-classification"], default=None, help="Task head to export (auto-detect if omitted)")
    ap.add_argument("--opt", action="store_true", help="Apply ONNX graph optimization (simplifier)")
    ap.add_argument("--opset", type=int, default=14)
    args = ap.parse_args()

    if not args.model:
        ap.error("--model is required")

    repo_or_dir = args.model
    is_local = Path(repo_or_dir).exists()
    subdir = args.name or (Path(repo_or_dir).name if is_local else repo_or_dir)
    base = Path(args.out_dir).resolve() / subdir
    # Ensure we export directly into the expected public models target
    onnx_dir = base / "onnx"
    onnx_dir.mkdir(parents=True, exist_ok=True)

    # Load model/tokenizer (supports local dir)
    print(f"[load] {repo_or_dir}")
    tokenizer = AutoTokenizer.from_pretrained(
        repo_or_dir,
        token=os.environ.get("HF_TOKEN"),
        local_files_only=is_local,
    )
    model = None
    if args.task:
        if args.task == "token-classification":
            model = AutoModelForTokenClassification.from_pretrained(repo_or_dir, token=os.environ.get("HF_TOKEN"), local_files_only=is_local)
        else:
            model = AutoModelForSequenceClassification.from_pretrained(repo_or_dir, token=os.environ.get("HF_TOKEN"), local_files_only=is_local)
    else:
        # auto-detect by config architectures when possible
        cfg = None
        try:
            cfg = AutoConfig.from_pretrained(repo_or_dir, token=os.environ.get("HF_TOKEN"), local_files_only=is_local)
        except Exception:
            cfg = None
        archs = [a.lower() for a in (getattr(cfg, "architectures", []) or [])]
        picked = None
        for a in archs:
            if "tokenclassification" in a or "token_classification" in a:
                picked = "token-classification"; break
            if "sequenceclassification" in a or "sequence_classification" in a:
                picked = "sequence-classification"; break
        if picked == "sequence-classification":
            model = AutoModelForSequenceClassification.from_pretrained(repo_or_dir, token=os.environ.get("HF_TOKEN"), local_files_only=is_local)
        else:
            # default to token-classification (works for NER models)
            try:
                model = AutoModelForTokenClassification.from_pretrained(repo_or_dir, token=os.environ.get("HF_TOKEN"), local_files_only=is_local)
            except Exception:
                # fallback to sequence classification if token head unavailable
                model = AutoModelForSequenceClassification.from_pretrained(repo_or_dir, token=os.environ.get("HF_TOKEN"), local_files_only=is_local)

    # Copy auxiliary files
    try:
        if is_local:
            # Copy directly from local dir if present
            for fname in ["tokenizer.json", "vocab.txt", "tokenizer_config.json", "config.json", "special_tokens_map.json"]:
                src = Path(repo_or_dir) / fname
                if src.exists():
                    from shutil import copyfile
                    dst = base / fname
                    copyfile(src, dst)
                    print(f"[copy] {fname} -> {dst}")
        else:
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

    # Prepare fast tokenizer assets in target directory
    try:
        ok_fast = ensure_fast_tokenizer(repo_or_dir, base, local_only=is_local)
        if not ok_fast:
            ok_fast = try_build_fast_tokenizer_fallback(repo_or_dir, base, tokenizer, Path(repo_or_dir) if is_local else None)
        if not ok_fast:
            print("[tok] ERROR: fast tokenizer not available; offsets will be unavailable in the browser")
        else:
            fix_tokenizer_config_fast(base)
    except Exception as e:
        print(f"[tok] tokenizer prep failed: {e}")

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

