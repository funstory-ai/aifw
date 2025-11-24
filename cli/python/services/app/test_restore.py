import unittest
import os, sys
try:
    # When executed as a package (recommended)
    from .anonymizer import AnonymizerWrapper
except Exception:
    # Fallback: allow running from this directory via `python -m unittest test_restore.py`
    PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
    if PROJECT_ROOT not in sys.path:
        sys.path.insert(0, PROJECT_ROOT)
    from services.presidio_service.app.anonymizer import AnonymizerWrapper


class DummyAnalyzer:
    def analyze(self, text: str, language: str = 'en'):
        # Return no entities; we'll test restore directly with crafted placeholders
        return []


class TestRestore(unittest.TestCase):
    def setUp(self):
        self.wrapper = AnonymizerWrapper(DummyAnalyzer())

    def test_exact_placeholder_restore(self):
        placeholders = {"__PII_EMAIL_ADDRESS_761b3e66__": "test@example.com"}
        text = "我的邮箱是 __PII_EMAIL_ADDRESS_761b3e66__"
        out = self.wrapper.restore(text, placeholders)
        self.assertEqual(out, "我的邮箱是 test@example.com")

    def test_missing_underscores_variant(self):
        placeholders = {"__PII_EMAIL_ADDRESS_761b3e66__": "test@example.com"}
        text = "我的邮箱是 PII_EMAIL_ADDRESS_761b3e66"
        out = self.wrapper.restore(text, placeholders)
        self.assertEqual(out, "我的邮箱是 test@example.com")

    def test_leaked_suffix_after_original(self):
        placeholders = {"__PII_EMAIL_ADDRESS_0b9df4b0__": "test@example.com"}
        text = "我的邮箱是 test@example.com0b9df4b0__"
        out = self.wrapper.restore(text, placeholders)
        self.assertEqual(out, "我的邮箱是 test@example.com")

    def test_overlapping_entities_prefer_longer(self):
        # Ensure independent of restore, the function does not break when overlapping-like patterns appear
        placeholders = {
            "__PII_URL_a37ec55b__": "example.com",
            "__PII_EMAIL_ADDRESS_6fbb5771__": "test@example.com",
        }
        text = "站点 example.com 和邮箱 __PII_EMAIL_ADDRESS_6fbb5771__"
        out = self.wrapper.restore(text, placeholders)
        self.assertEqual(out, "站点 example.com 和邮箱 test@example.com")


if __name__ == "__main__":
    unittest.main()


