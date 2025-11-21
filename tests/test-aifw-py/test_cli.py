#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
CLI test for aifw-py:
- Initialize library
- Mask/restore (single) for EN and ZH (single-line and multi-line)
- Mask/restore (batch)
- Deinit (which triggers core shutdown)
"""
import os
import sys
import json
import importlib
import importlib.util


def load_aifw_py_package():
    """
    Load libs/aifw-py as a package named 'aifw_py' so that relative imports work.
    """
    repo_root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
    pkg_dir = os.path.join(repo_root, "libs", "aifw-py")
    init_py = os.path.join(pkg_dir, "__init__.py")
    if not os.path.exists(init_py):
        raise RuntimeError("aifw-py package not found at: %s" % pkg_dir)
    spec = importlib.util.spec_from_file_location(
        "aifw_py",
        init_py,
        submodule_search_locations=[pkg_dir],
    )
    mod = importlib.util.module_from_spec(spec)
    sys.modules["aifw_py"] = mod  # register as package
    loader = spec.loader
    assert loader is not None
    loader.exec_module(mod)
    return mod


def pretty(obj):
    try:
        return json.dumps(obj, ensure_ascii=False, indent=2)
    except Exception:
        return str(obj)


def main():
    aifw_pkg = load_aifw_py_package()
    aifw = importlib.import_module("aifw_py.libaifw")

    print("[aifw-py-test] init...")
    aifw.init({
        # Optional mask config example:
        "maskConfig": { "maskAll": True }
    })

    cases_single = [
        ("en-single",
         "My name is John Doe, I live at 221B Baker Street, London. Email: john.doe@example.com, Phone: +1-202-555-0188.",
         "auto"),
        ("zh-single",
         "我叫张三，住在北京市海淀区中关村大街27号，邮箱是 zhangsan@example.com，电话是13812345678。",
         "auto"),
        ("en-multiline",
         "Contact: Jane Smith\nAddress: 5th Ave, New York, NY 10001\nEmail: jane.smith@sample.org\nPhone: 212-555-0101",
         "auto"),
        ("zh-multiline",
         "联系人：李四\n地址：上海市浦东新区世纪大道100号\n邮箱：lisi@example.cn\n电话：+86 139-0000-0000",
         "auto"),
    ]

    for name, text, lang in cases_single:
        print(f"\n[aifw-py-test] single: {name}")
        masked, meta = aifw.mask_text(text, lang)
        print("masked:", masked)
        print("meta (bytes len):", len(meta))
        restored = aifw.restore_text(masked, meta)
        print("restored:", restored)

    # Batch tests (mix strings and {text, language})
    batch_inputs = [
        "Alice lives at 1600 Amphitheatre Parkway, Mountain View. Email: alice@example.com",
        {"text": "王五的地址是广州市天河区体育西路101号，电话：13912345678", "language": "auto"},
        "Bob: +44 20 7946 0958; Email: bob.jr@example.co.uk; Address: 10 Downing St, London",
    ]

    print("\n[aifw-py-test] batch mask...")
    batch_masked = aifw.mask_text_batch(batch_inputs)
    for i, item in enumerate(batch_masked):
        print(f"  [{i}] masked:", item["text"])
        print(f"  [{i}] meta len:", len(item["maskMeta"]))

    print("\n[aifw-py-test] batch restore...")
    batch_restored = aifw.restore_text_batch(batch_masked)
    for i, item in enumerate(batch_restored):
        print(f"  [{i}] restored:", item["text"])

    print("\n[aifw-py-test] deinit (and shutdown)...")
    aifw.deinit()
    print("[aifw-py-test] done.")


if __name__ == "__main__":
    sys.exit(main() or 0)


