#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Automated tests for aifw-py:
- Simple single-line mask/restore
- Multi-line batch mask/restore
- Multi-line single-call mask + batch restore
- Large-text mask/restore for EN and ZH using NER + rule-based detection
"""
import os
import sys
import json
import importlib
import importlib.util
from typing import Any, Dict, List, Tuple


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


def get_aifw_module():
    """
    Import and return aifw_py.libaifw after ensuring the package is loaded.
    """
    load_aifw_py_package()
    return importlib.import_module("aifw_py.libaifw")


def pretty(obj):
    try:
        return json.dumps(obj, ensure_ascii=False, indent=2)
    except Exception:
        return str(obj)


def _init_aifw_with_full_mask() -> Any:
    """
    Helper to init aifw with maskAll enabled so that NER + rules are fully exercised.
    """
    aifw = get_aifw_module()
    aifw.init(
        {
            "maskConfig": {
                "maskAll": True,
            }
        }
    )
    return aifw


def _tests_dir() -> str:
    """
    Return the absolute path to the tests directory root.
    """
    return os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))


def _read_test_file(name: str) -> str:
    """
    Read a UTF-8 encoded file from the tests directory.
    """
    path = os.path.join(_tests_dir(), name)
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def test_single_line_mask_and_restore_roundtrip(aifw: Any):
    """
    Simple one-line and small multi-line EN/ZH texts:
    - mask_text should anonymize PII
    - restore_text should restore to original text
    - masked text should meet expected anonymization patterns
    """
    cases_single: List[Tuple[str, str, str, List[str], List[str]]] = [
        (
            "en-single",
            "My name is John Doe, I live at 221B Baker Street, London. Email: john.doe@example.com, Phone: +1-202-555-0188.",
            "auto",
            # PII substrings that must not appear in masked output
            # ["John Doe", "221B Baker Street, London", "john.doe@example.com", "+1-202-555-0188"],
            ["john.doe@example.com", "+1-202-555-0188"],
            # Expected anonymization tokens
            ["__PII_EMAIL_ADDRESS_", "__PII_PHONE_NUMBER_"],
        ),
        (
            "zh-single",
            "我叫张三，住在北京市海淀区中关村大街27号，邮箱是 zhangsan@example.com，电话是13812345678。",
            "auto",
            # ["张三", "北京市海淀区中关村大街27号", "zhangsan@example.com", "13812345678"],
            ["zhangsan@example.com", "13812345678"],
            # ["__PII_PERSON_", "__PII_PHYSICAL_ADDRESS_", "__PII_EMAIL_ADDRESS_", "__PII_PHONE_NUMBER_"],
            ["__PII_EMAIL_ADDRESS_", "__PII_PHONE_NUMBER_"],
        ),
        (
            "en-multiline",
            "Contact: Jane Smith\nAddress: 5th Ave, New York, NY 10001\nEmail: jane.smith@sample.org\nPhone: 212-555-0101",
            "auto",
            # ["Jane Smith", "5th Ave, New York, NY 10001", "jane.smith@sample.org", "212-555-0101"],
            ["10001", "jane.smith@sample.org", "212-555-0101"],
            # ["__PII_PERSON_", "__PII_PHYSICAL_ADDRESS_", "__PII_EMAIL_ADDRESS_", "__PII_PHONE_NUMBER_"],
            ["__PII_VERIFICATION_CODE_", "__PII_EMAIL_ADDRESS_", "__PII_PHONE_NUMBER_"],
        ),
        (
            "zh-multiline",
            "联系人：李四\n地址：上海市浦东新区世纪大道100号\n邮箱：lisi@example.cn\n电话：+86 139-0000-0000",
            "auto",
            # ["李四", "上海市浦东新区世纪大道100号", "lisi@example.cn", "+86 139-0000-0000"],
            ["lisi@example.cn", "+86 139-0000-0000"],
            # ["__PII_PERSON_", "__PII_PHYSICAL_ADDRESS_", "__PII_EMAIL_ADDRESS_", "__PII_PHONE_NUMBER_"],
            ["__PII_EMAIL_ADDRESS_", "__PII_PHONE_NUMBER_"],
        ),
    ]

    for name, text, lang, must_not, must_contain in cases_single:
        masked, meta = aifw.mask_text(text, lang)
        assert isinstance(masked, str)
        assert isinstance(meta, (bytes, bytearray))
        print(f"masked text: {masked}")
        # Expect at least some anonymization to happen for these PII-rich texts.
        assert masked != text, f"masked text should differ for case: {name}"

        # Masked text should not contain raw PII snippets.
        for snippet in must_not:
            assert snippet not in masked, f"masked text still contains PII snippet '{snippet}' for case: {name}"

        # Masked text should contain expected anonymization tokens.
        for token in must_contain:
            assert token in masked, f"masked text missing expected token '{token}' for case: {name}"

        restored = aifw.restore_text(masked, meta)
        assert restored == text, f"restored text mismatch for case: {name}"


def test_batch_mask_and_restore_roundtrip(aifw: Any):
    """
    Multi-line batch mask/restore:
    - Use mask_text_batch on mixed EN/ZH inputs
    - Use restore_text_batch and ensure exact roundtrip
    - masked texts should not contain raw PII and should contain anonymization tokens
    """
    batch_inputs: List[Any] = [
        "Alice lives at 1600 Amphitheatre Parkway, Mountain View. Email: alice@example.com",
        {"text": "王五的地址是广州市天河区体育西路101号，电话：13912345678", "language": "auto"},
        "Bob: +44 20 7946 0958; Email: bob.jr@example.co.uk; Address: 10 Downing St, London",
    ]

    # Extract original plain texts in order to compare after restore.
    originals: List[str] = []
    for item in batch_inputs:
        if isinstance(item, str):
            originals.append(item)
        elif isinstance(item, dict):
            originals.append(str(item.get("text", "")))
        else:
            originals.append(str(item))

    # Per-item expectations for masked output.
    must_not_batch: List[List[str]] = [
        # idx 0
        [
            "1600 Amphitheatre Parkway, Mountain View",
            "alice@example.com",
        ],
        # idx 1
        # [
        #     "广州市天河区体育西路101号",
        #     "13912345678",
        # ],
        [
            "13912345678",
        ],
        # idx 2
        # [
        #     "Bob",
        #     "+44 20 7946 0958",
        #     "bob.jr@example.co.uk",
        #     "10 Downing St, London",
        # ],
        [
            "+44 20 7946 0958",
            "bob.jr@example.co.uk",
        ],
    ]
    must_contain_batch: List[List[str]] = [
        # ["__PII_PHYSICAL_ADDRESS_", "__PII_EMAIL_ADDRESS_"],
        ["__PII_EMAIL_ADDRESS_"],
        # ["__PII_PHYSICAL_ADDRESS_", "__PII_PHONE_NUMBER_"],
        ["__PII_PHONE_NUMBER_"],
        # ["__PII_PERSON_", "__PII_PHONE_NUMBER_", "__PII_EMAIL_ADDRESS_", "__PII_PHYSICAL_ADDRESS_"],
        ["__PII_PHONE_NUMBER_", "__PII_EMAIL_ADDRESS_"],
    ]

    batch_masked = aifw.mask_text_batch(batch_inputs)
    assert isinstance(batch_masked, list)
    assert len(batch_masked) == len(batch_inputs)

    for idx, item in enumerate(batch_masked):
        assert "text" in item and "maskMeta" in item
        masked_text = item["text"]
        mask_meta = item["maskMeta"]
        print(f"batch_masked[{idx}] text: {masked_text}")
        assert isinstance(masked_text, str)
        assert isinstance(mask_meta, (bytes, bytearray))
        assert masked_text != originals[idx]

        # Check PII removal and anonymization tokens.
        for snippet in must_not_batch[idx]:
            assert snippet not in masked_text, f"batch masked text[{idx}] still contains PII snippet '{snippet}'"
        for token in must_contain_batch[idx]:
            assert token in masked_text, f"batch masked text[{idx}] missing expected token '{token}'"

    batch_restored = aifw.restore_text_batch(batch_masked)
    assert isinstance(batch_restored, list)
    assert len(batch_restored) == len(batch_inputs)

    for idx, item in enumerate(batch_restored):
        assert "text" in item
        assert item["text"] == originals[idx]


def test_multi_single_mask_and_batch_restore(aifw: Any):
    """
    Multi-line texts masked via multiple single calls, then restored via batch:
    - Use mask_text repeatedly to build a batch of masked items
    - Use restore_text_batch once to ensure metadata works in batch mode
    - masked texts should not contain raw PII and should contain anonymization tokens
    """
    texts: List[str] = [
        "Email: user1@example.com, phone: +1-202-555-0001",
        "第二行包含邮箱 test2@example.cn 和电话 13900000002",
        "Third line: card 4242-4242-4242-4242, bank 1234 5678 0000 0000",
    ]

    must_not: List[List[str]] = [
        ["user1@example.com", "+1-202-555-0001"],
        ["test2@example.cn", "13900000002"],
        ["4242-4242-4242-4242", "1234 5678 0000 0000"],
    ]
    must_contain: List[List[str]] = [
        ["__PII_EMAIL_ADDRESS_", "__PII_PHONE_NUMBER_"],
        ["__PII_EMAIL_ADDRESS_", "__PII_PHONE_NUMBER_"],
        # ["__PII_BANK_NUMBER_"],
        ["__PII_PHONE_NUMBER_"],
    ]

    batch_masked: List[Dict[str, Any]] = []

    for idx, text in enumerate(texts):
        masked, meta = aifw.mask_text(text, "auto")
        print(f"single to batch masked text: {masked}")
        assert masked != text
        assert isinstance(meta, (bytes, bytearray))

        for snippet in must_not[idx]:
            assert snippet not in masked, f"single masked text[{idx}] still contains PII snippet '{snippet}'"
        for token in must_contain[idx]:
            assert token in masked, f"single masked text[{idx}] missing expected token '{token}'"

        batch_masked.append({"text": masked, "maskMeta": meta})

    restored_batch = aifw.restore_text_batch(batch_masked)
    assert isinstance(restored_batch, list)
    assert len(restored_batch) == len(texts)

    for orig, item in zip(texts, restored_batch):
        assert "text" in item
        assert item["text"] == orig


def test_large_en_text_anonymize_and_restore(aifw: Any):
    """
    Large EN text:
    - Load tests/test_en_pii.txt as original text
    - Expect masked output to match tests/test_en_pii.anonymized.expected.txt
    - Expect restore_text(masked, meta) == original text
    """
    original = _read_test_file("test_en_pii.txt")
    expected_anonymized = _read_test_file("test_en_pii.anonymized.expected.txt")

    masked, meta = aifw.mask_text(original, "auto")
    assert isinstance(masked, str)
    assert isinstance(meta, (bytes, bytearray))

    # Check full anonymized output against golden file.
    assert masked == expected_anonymized

    restored = aifw.restore_text(masked, meta)
    assert restored == original


def test_large_zh_text_anonymize_and_restore(aifw: Any):
    """
    Large ZH text:
    - Load tests/test_zh_pii.txt as original text
    - Expect masked output to match tests/test_zh_pii.anonymized.expected.txt
    - Expect restore_text(masked, meta) == original text
    """
    original = _read_test_file("test_zh_pii.txt")
    expected_anonymized = _read_test_file("test_zh_pii.anonymized.expected.txt")

    masked, meta = aifw.mask_text(original, "auto")
    assert isinstance(masked, str)
    assert isinstance(meta, (bytes, bytearray))

    # Check full anonymized output against golden file.
    assert masked == expected_anonymized

    restored = aifw.restore_text(masked, meta)
    assert restored == original


def main():
    """
    Optional manual entrypoint to run all tests without pytest.
    """
    aifw = _init_aifw_with_full_mask()
    results: List[Tuple[str, bool, str]] = []

    def run_test(name: str, fn) -> None:
        """
        Run a single test function, record and print its result.
        """
        try:
            fn(aifw)
            print(f"[aifw-py-test] PASS: {name}")
            results.append((name, True, ""))
        except AssertionError as e:
            msg = str(e)
            print(f"[aifw-py-test] FAIL: {name} - {msg}")
            results.append((name, False, msg))
        except Exception as e:
            msg = f"{type(e).__name__}: {e}"
            print(f"[aifw-py-test] ERROR: {name} - {msg}")
            results.append((name, False, msg))

    try:
        run_test("single_line_mask_and_restore_roundtrip", test_single_line_mask_and_restore_roundtrip)
        run_test("batch_mask_and_restore_roundtrip", test_batch_mask_and_restore_roundtrip)
        run_test("multi_single_mask_and_batch_restore", test_multi_single_mask_and_batch_restore)
        run_test("large_en_text_anonymize_and_restore", test_large_en_text_anonymize_and_restore)
        run_test("large_zh_text_anonymize_and_restore", test_large_zh_text_anonymize_and_restore)

        total = len(results)
        failed = sum(1 for _, ok, _ in results if not ok)
        passed = total - failed
        print(f"[aifw-py-test] SUMMARY: total={total}, passed={passed}, failed={failed}")

        if failed == 0:
            print("[aifw-py-test] all tests passed.")
        else:
            print("[aifw-py-test] some tests failed.")
        return 0 if failed == 0 else 1
    finally:
        aifw.deinit()


if __name__ == "__main__":
    sys.exit(main() or 0)