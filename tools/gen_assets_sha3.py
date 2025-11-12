#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Generate SHA3-256 hashes for model_quantized.onnx files under OneAIFW-Assets/models
and ORT wasm files under OneAIFW-Assets/wasm. Output a JSON manifest to the
project's assets directory.

Usage:
  python tools/gen_assets_sha3.py --assets ../OneAIFW-Assets --out assets/oneaifw_assets_hashes.json

If --assets is omitted, defaults to ../OneAIFW-Assets relative to this script.
If --out is omitted, defaults to <project_root>/assets/oneaifw_assets_hashes.json.
"""
import argparse
import hashlib
import json
import os
import sys
from typing import Dict, Any


def sha3_256_hex_prefixed(file_path: str) -> str:
    h = hashlib.sha3_256()
    with open(file_path, 'rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return '0x' + h.hexdigest()


def read_version_from_hello(assets_root: str) -> str:
    hello_path = os.path.join(assets_root, 'hello.json')
    if not os.path.isfile(hello_path):
        return ''
    try:
        with open(hello_path, 'r', encoding='utf-8') as f:
            obj = json.load(f)
        v = obj.get('version')
        return str(v) if v is not None else ''
    except Exception:
        return ''


def collect_model_hashes(models_root: str) -> Dict[str, Dict[str, str]]:
    """
    Scan models_root like:
      models/<org>/<model>/onnx/model_quantized.onnx
    Return:
      { "<org>/<model>": { "onnx/model_quantized.onnx": "0x..." }, ... }
    """
    result: Dict[str, Dict[str, str]] = {}
    if not os.path.isdir(models_root):
        return result
    for org in sorted(os.listdir(models_root)):
        org_dir = os.path.join(models_root, org)
        if not os.path.isdir(org_dir):
            continue
        for model in sorted(os.listdir(org_dir)):
            model_dir = os.path.join(org_dir, model)
            if not os.path.isdir(model_dir):
                continue
            onnx_path = os.path.join(model_dir, 'onnx', 'model_quantized.onnx')
            if os.path.isfile(onnx_path):
                model_id = f'{org}/{model}'
                try:
                    digest = sha3_256_hex_prefixed(onnx_path)
                except Exception as e:
                    print(f'[WARN] hash failed for {onnx_path}: {e}', file=sys.stderr)
                    continue
                result[model_id] = {'onnx/model_quantized.onnx': digest}
    return result


def collect_wasm_hashes(wasm_root: str) -> Dict[str, str]:
    """
    Scan wasm_root for *.wasm files and hash them.
    Return:
      { "<filename>": "0x...", ... }
    """
    result: Dict[str, str] = {}
    if not os.path.isdir(wasm_root):
        return result
    for name in sorted(os.listdir(wasm_root)):
        if not name.endswith('.wasm'):
            continue
        p = os.path.join(wasm_root, name)
        if os.path.isfile(p):
            try:
                digest = sha3_256_hex_prefixed(p)
            except Exception as e:
                print(f'[WARN] hash failed for {p}: {e}', file=sys.stderr)
                continue
            result[name] = digest
    return result


def main() -> int:
    script_dir = os.path.dirname(os.path.abspath(__file__))
    project_root = os.path.abspath(os.path.join(script_dir, '..'))
    default_assets_dir = os.path.abspath(os.path.join(project_root, '..', 'OneAIFW-Assets'))
    default_out = os.path.join(project_root, 'assets', 'oneaifw_assets_hashes.json')

    parser = argparse.ArgumentParser(description='Generate SHA3-256 manifest for OneAIFW-Assets resources.')
    parser.add_argument('--assets', type=str, default=default_assets_dir, help='Path to OneAIFW-Assets directory')
    parser.add_argument('--out', type=str, default=default_out, help='Output JSON file path (under project assets)')
    args = parser.parse_args()

    assets_root = os.path.abspath(args.assets)
    models_root = os.path.join(assets_root, 'models')
    wasm_root = os.path.join(assets_root, 'wasm')
    out_path = os.path.abspath(args.out)

    if not os.path.isdir(assets_root):
        print(f'[ERROR] assets root not found: {assets_root}', file=sys.stderr)
        return 2

    version = read_version_from_hello(assets_root)
    models_hashes = collect_model_hashes(models_root)
    wasm_hashes = collect_wasm_hashes(wasm_root)

    manifest: Dict[str, Any] = {
        'source': assets_root,
        'version': version,
        'models': models_hashes,
        'wasm': wasm_hashes,
    }

    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, 'w', encoding='utf-8') as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2, sort_keys=True)

    print(f'[OK] wrote manifest: {out_path}')
    print(f'      models: {len(models_hashes)} entries, wasm: {len(wasm_hashes)} entries')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())


