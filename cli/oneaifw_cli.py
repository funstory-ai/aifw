#!/usr/bin/env python3
"""OneAIFW CLI - anonymize/restore/analyze/call using local in-process API.

Usage examples:
  python -m cli.oneaifw_cli anonymize --text "My email is test@example.com"
  python -m cli.oneaifw_cli restore --text "Hello __PII_EMAIL_ADDRESS_abcd1234__" \
      --placeholders '{"__PII_EMAIL_ADDRESS_abcd1234__":"test@example.com"}'
  echo "My phone is 13800001111" | python -m cli.oneaifw_cli anonymize -
"""

import sys
import json
import argparse
import os

# Ensure project root on path when running as module from repo root
PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

from services.app import local_api


def read_stdin_if_dash(value: str) -> str:
    if value == "-":
        return sys.stdin.read()
    return value


def cmd_anonymize(args: argparse.Namespace) -> int:
    text = read_stdin_if_dash(args.text)
    result = local_api.anonymize(text=text)
    print(json.dumps(result, ensure_ascii=False))
    return 0


def cmd_restore(args: argparse.Namespace) -> int:
    text = read_stdin_if_dash(args.text)
    placeholders_map = json.loads(args.placeholders) if args.placeholders else {}
    restored = local_api.restore(text=text, placeholders_map=placeholders_map)
    print(json.dumps({"text": restored}, ensure_ascii=False))
    return 0


def cmd_analyze(args: argparse.Namespace) -> int:
    text = read_stdin_if_dash(args.text)
    items = local_api.analyze(text=text)
    payload = {"items": [i.__dict__ for i in items]}
    print(json.dumps(payload, ensure_ascii=False))
    return 0


def cmd_call(args: argparse.Namespace) -> int:
    text = read_stdin_if_dash(args.text)
    output = local_api.call(
        text=text,
        api_key_file=args.api_key_file,
        model=args.model,
        temperature=args.temperature,
        language=args.language or "en",
    )
    print(output)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="oneaifw", description="OneAIFW CLI")
    sub = parser.add_subparsers(dest="command", required=True)

    p_anonymize = sub.add_parser("anonymize", help="Anonymize input text")
    p_anonymize.add_argument("text", help="Text to anonymize or '-' to read from stdin")
    p_anonymize.set_defaults(func=cmd_anonymize)

    p_restore = sub.add_parser("restore", help="Restore placeholders in text")
    p_restore.add_argument("text", help="Text with placeholders or '-' to read from stdin")
    p_restore.add_argument("--placeholders", "-p", help="JSON map of placeholders to original values")
    p_restore.set_defaults(func=cmd_restore)

    p_analyze = sub.add_parser("analyze", help="Analyze PII entities in text")
    p_analyze.add_argument("text", help="Text to analyze or '-' to read from stdin")
    p_analyze.set_defaults(func=cmd_analyze)

    p_call = sub.add_parser("call", help="Call LLM with anonymize→LLM→restore")
    p_call.add_argument("text", help="Text to send or '-' to read from stdin")
    p_call.add_argument("--model", help="LiteLLM model name (e.g., gpt-4o-mini, glm-4)")
    p_call.add_argument("--temperature", type=float, default=0.0)
    p_call.add_argument("--api-key-file", help="Path to JSON config containing openai-api-key/base-url/model for OpenAI-compatible gateway")
    p_call.add_argument("--language", help="Input language for Presidio analysis (default 'en')")
    p_call.set_defaults(func=cmd_call)

    return parser


def main(argv=None) -> int:
    argv = argv if argv is not None else sys.argv[1:]
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())


