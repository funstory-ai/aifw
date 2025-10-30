#!/usr/bin/env python3
"""OneAIFW CLI - direct (in-process) and HTTP modes.

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

import subprocess
import shlex
import time
import urllib.request
import urllib.error
import signal
import logging
from datetime import datetime

from services.app.aifw_utils import cleanup_monthly_logs

def read_stdin_if_dash(value: str) -> str:
    if value == "-":
        return sys.stdin.read()
    return value


def resolve_work_dir(provided: str | None) -> str:
    base = provided or os.environ.get("AIFW_WORK_DIR")
    if not base:
        base = os.path.expanduser("~/.aifw")
    try:
        os.makedirs(base, exist_ok=True)
    except Exception:
        pass
    return base


def _parse_scopes(scopes: str | None) -> set[str]:
    raw = (scopes or "app,uvicorn").strip()
    parts = [p.strip().lower() for p in raw.split(',') if p.strip()]
    return set(parts or ["app", "uvicorn"])


def _candidate_config_paths(provided: str | None, work_dir_arg: str | None) -> list[str]:
    paths: list[str] = []
    def add(p: str | None):
        if not p:
            return
        p = os.path.abspath(os.path.expanduser(p))
        if p not in paths:
            paths.append(p)
    add(provided)
    add(os.environ.get("AIFW_CONFIG"))
    wd = resolve_work_dir(work_dir_arg)
    add(os.path.join(wd, "aifw.yaml"))
    xdg = os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config"))
    add(os.path.join(xdg, "aifw", "aifw.yaml"))
    add(os.path.expanduser("~/.aifw/aifw.yaml"))
    add("/etc/aifw/aifw.yaml")
    return paths


def _load_config(config_path: str | None) -> dict:
    if not config_path:
        return {}
    try:
        with open(config_path, 'r', encoding='utf-8') as f:
            text = f.read()
        try:
            return json.loads(text)
        except Exception:
            try:
                import yaml  # type: ignore
                return yaml.safe_load(text) or {}
            except Exception:
                return {}
    except Exception:
        return {}


def _get_effective_with_env(arg_val, env_names: list[str], cfg_val, default_val=None):
    if arg_val not in (None, ""):
        return arg_val
    for name in env_names:
        val = os.environ.get(name)
        if val not in (None, ""):
            return val
    return cfg_val if cfg_val not in (None, "") else default_val


def _build_headers(base_headers: dict[str, str] | None, cfg: dict, args: argparse.Namespace) -> dict[str, str]:
    headers = dict(base_headers or {})
    auth = _get_effective_with_env(getattr(args, 'http_api_key', None), ['AIFW_HTTP_API_KEY'], cfg.get('http_api_key'), None)
    if auth:
        headers['Authorization'] = str(auth)
    return headers

def _find_and_load_config(config_arg: str | None, work_dir_arg: str | None) -> tuple[dict, str | None]:
    cfg_path = None
    for p in _candidate_config_paths(config_arg, work_dir_arg):
        if os.path.exists(p):
            cfg_path = p
            break
    return _load_config(cfg_path), cfg_path


def _monthly_log_path(base_path: str, now: datetime | None = None) -> str:
    """Append -YYYY-MM before extension (or at end) for monthly logs."""
    now = now or datetime.now()
    ym = now.strftime("%Y-%m")
    base_path = os.path.expanduser(base_path)
    base_dir = os.path.dirname(base_path)
    file_name = os.path.basename(base_path)
    if file_name.endswith('.log'):
        stem = file_name[:-4]
        rotated = f"{stem}-{ym}.log"
    else:
        rotated = f"{file_name}-{ym}.log"
    return os.path.abspath(os.path.join(base_dir, rotated))


def _pidfile_candidates(port: int, work_dir_arg: str | None) -> list[str]:
    bases = []
    seen = set()

    def _add(base: str | None):
        if not base:
            return
        # Normalize for dedupe (expanduser + abspath)
        norm = os.path.abspath(os.path.expanduser(base))
        if norm not in seen:
            seen.add(norm)
            bases.append(norm)

    # 1) user-provided/arg directory (resolved to ensure it exists)
    if work_dir_arg:
        _add(resolve_work_dir(work_dir_arg))
    # 2) environment directory
    _add(os.environ.get("AIFW_WORK_DIR"))
    # 3) default home directory
    _add("~/.aifw")

    return [os.path.join(b, f"aifw-server-{port}.pid") for b in bases]


def _find_existing_pidfile(port: int, work_dir_arg: str | None) -> str | None:
    for pf in _pidfile_candidates(port, work_dir_arg):
        if os.path.exists(pf):
            return pf
    return None


def _is_pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except Exception:
        return False


def _server_alive_on_port(port: int) -> bool:
    try:
        url = f"http://127.0.0.1:{port}/api/health"
        with urllib.request.urlopen(url, timeout=0.7) as resp:
            return 200 <= resp.getcode() < 300
    except Exception:
        return False


def _write_pidfile_with_fallbacks(preferred_dir: str, port: int, pid: int) -> str | None:
    # Use unified candidate generation (includes de-dup for env/home)
    pidfiles = _pidfile_candidates(port, preferred_dir)
    for pf in pidfiles:
        try:
            base = os.path.dirname(pf)
            os.makedirs(base, exist_ok=True)
            with open(pf, 'w') as f:
                f.write(str(pid))
            return pf
        except Exception:
            continue
    return None


def cmd_direct_call(args: argparse.Namespace) -> int:
    # Load config (if available)
    cfg, _ = _find_and_load_config(getattr(args, 'config', None), getattr(args, 'work_dir', None))
    # Configure logging destination and level for in-process run
    level = getattr(logging, (_get_effective_with_env(getattr(args, 'log_level', None), ['AIFW_LOG_LEVEL'], cfg.get('log_level'), 'INFO') or 'INFO').upper(), logging.INFO)
    scopes = _parse_scopes(_get_effective_with_env(getattr(args, 'log_scopes', None), ['AIFW_LOG_SCOPES'], cfg.get('log_scopes'), None))
    # Delay import so we can reconfigure module loggers after import
    from services.app import local_api  # noqa: WPS433
    # Reset module loggers to avoid duplicate handlers
    for name in [
        'services.app',
        'services.app.analyzer',
        'services.app.anonymizer',
        'services.app.llm_client',
    ]:
        lg = logging.getLogger(name)
        for h in list(lg.handlers):
            lg.removeHandler(h)
        lg.setLevel(level)
        lg.propagate = False
    # Third-party loggers default no more verbose than chosen level, min WARNING
    default_third_level = level if level >= logging.WARNING else logging.WARNING
    for name in [
        'presidio', 'presidio-analyzer', 'presidio-anonymizer',
        'LiteLLM', 'httpx',
    ]:
        if name.startswith('presidio'):
            set_level = level if ('presidio' in scopes or 'all' in scopes) else default_third_level
        elif name == 'LiteLLM' or name == 'httpx':
            set_level = level if ('litellm' in scopes or 'all' in scopes) else default_third_level
        else:
            set_level = default_third_level
        logging.getLogger(name).setLevel(set_level)

    handler: logging.Handler
    log_dest = _get_effective_with_env(getattr(args, 'log_dest', None), ['AIFW_LOG_DEST'], cfg.get('log_dest'), 'stdout')
    if log_dest == 'file':
        work_dir = resolve_work_dir(getattr(args, 'work_dir', None))
        base_log = _get_effective_with_env(getattr(args, 'log_file', None), ['AIFW_LOG_FILE'], cfg.get('log_file'), os.path.join(work_dir, 'aifw-direct.log'))
        log_file = _monthly_log_path(base_log)
        try:
            os.makedirs(os.path.dirname(log_file), exist_ok=True)
            handler = logging.FileHandler(log_file)
            # Cleanup old logs based on config (months)
            months_to_keep = int(_get_effective_with_env(None, ['AIFW_LOG_MONTHS_TO_KEEP'], cfg.get('log_months_to_keep'), 6) or 6)
            cleanup_monthly_logs(base_log, months_to_keep)
        except Exception:
            handler = logging.StreamHandler(sys.stdout)
    else:
        handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(logging.Formatter("%(asctime)s [%(levelname)s] %(name)s: %(message)s"))
    for name in [
        'services.app',
        'services.app.analyzer',
        'services.app.anonymizer',
        'services.app.llm_client',
    ]:
        logging.getLogger(name).addHandler(handler)

    text = read_stdin_if_dash(args.text)
    api_key_file = _get_effective_with_env(getattr(args, 'api_key_file', None), ['AIFW_API_KEY_FILE'], cfg.get('api_key_file'), None)
    api_key_file = os.path.abspath(api_key_file) if api_key_file else None
    stage = getattr(args, 'stage', 'restored') or 'restored'
    temp = float(_get_effective_with_env(getattr(args, 'temperature', None), ['AIFW_TEMPERATURE'], cfg.get('temperature'), 0.0) or 0.0)

    if stage == 'restored':
        output = local_api.call(
            text=text,
            api_key_file=api_key_file,
            model=None,
            temperature=temp,
        )
        print(output)
        return 0

    # For anonymized stages, run the in-process API internals explicitly
    from services.app.one_aifw_api import OneAIFWAPI  # lazy import
    from services.app.llm_client import LLMClient, load_llm_api_config
    api = OneAIFWAPI()
    language = api._analyzer_wrapper.detect_language(text)
    anon = api._anonymizer_wrapper.anonymize(text=text, operators=None, language=language)
    anonymized_text = anon.get('text', '')

    if stage == 'anonymized':
        print(anonymized_text)
        return 0

    if stage == 'anonymized_via_llm':
        if api_key_file:
            load_llm_api_config(api_key_file)
        llm = LLMClient()
        echoed = llm.call(text=anonymized_text, model=None, temperature=temp)
        print(echoed)
        return 0

    print(anonymized_text)
    return 0


def cmd_launch(args: argparse.Namespace) -> int:
    # Launch FastAPI service using uvicorn in background
    # Load config
    cfg, _ = _find_and_load_config(getattr(args, 'config', None), getattr(args, 'work_dir', None))
    port = int(_get_effective_with_env(getattr(args, 'port', None), ['AIFW_PORT'], cfg.get('port'), args.port or 8844))
    env = os.environ.copy()

    # Enforce global single instance per port: if running, report and exit
    if _server_alive_on_port(port):
        print(f"aifw is already running at http://localhost:{port} (health check passed).")
        return 1
    existing_pf = _find_existing_pidfile(port, getattr(args, 'work_dir', None))
    if existing_pf:
        try:
            with open(existing_pf, 'r') as f:
                pid_txt = f.read().strip()
            pid = int(pid_txt)
            if _is_pid_alive(pid):
                print(f"aifw already running (pidfile: {existing_pf}, PID: {pid}).")
                return 1
        except Exception:
            # stale or unreadable pidfile; ignore and continue to launch
            pass

    api_key_file = _get_effective_with_env(getattr(args, 'api_key_file', None), ['AIFW_API_KEY_FILE'], cfg.get('api_key_file'), None)
    if not api_key_file:
        print("Error: api-key-file is required. Set via --api-key-file, or env AIFW_API_KEY_FILE, or config aifw.yaml.")
        return 1
    if api_key_file:
        env["AIFW_API_KEY_FILE"] = os.path.abspath(api_key_file)
    # Propagate HTTP API key to backend if provided (or via env/config)
    http_api_key = _get_effective_with_env(getattr(args, 'http_api_key', None), ['AIFW_HTTP_API_KEY'], cfg.get('http_api_key'), None)
    if http_api_key:
        env["AIFW_HTTP_API_KEY"] = str(http_api_key)
    # Ensure backend package importable
    env["PYTHONPATH"] = (
        (PROJECT_ROOT + (os.pathsep + env.get("PYTHONPATH", "") if env.get("PYTHONPATH") else ""))
    )
    # Import path for app: services.app.main:app
    log_level = (_get_effective_with_env(getattr(args, 'log_level', None), ['AIFW_LOG_LEVEL'], cfg.get('log_level'), 'info') or 'info').lower()
    # Build uvicorn log-config to include root logger so app logs are captured
    work_dir = resolve_work_dir(getattr(args, 'work_dir', None))
    logcfg_path = os.path.join(work_dir, f"aifw-uvicorn-{port}.json")
    try:
        scopes = _parse_scopes(_get_effective_with_env(getattr(args, 'log_scopes', None), ['AIFW_LOG_SCOPES'], cfg.get('log_scopes'), None))
        app_level = log_level.upper()
        # Default third-party not more verbose than app level, min WARNING
        default_third = 'WARNING'
        if app_level in ('ERROR', 'CRITICAL', 'FATAL'):
            default_third = 'ERROR'
        pres_level = app_level if ('presidio' in scopes or 'all' in scopes) else default_third
        llm_level = app_level if ('litellm' in scopes or 'all' in scopes) else default_third
        logcfg = {
            "version": 1,
            "disable_existing_loggers": False,
            "formatters": {
                "default": {
                    "()": "uvicorn.logging.DefaultFormatter",
                    "fmt": "%(asctime)s [%(levelname)s] %(name)s: %(message)s",
                    "datefmt": "%Y-%m-%d %H:%M:%S",
                }
            },
            "handlers": {
                "default": {
                    "class": "logging.StreamHandler",
                    "formatter": "default",
                    "stream": "ext://sys.stdout",
                }
            },
            "root": {"level": log_level.upper(), "handlers": ["default"]},
            "loggers": {
                "uvicorn": {"level": log_level.upper(), "handlers": ["default"], "propagate": False},
                "uvicorn.error": {"level": log_level.upper(), "handlers": ["default"], "propagate": False},
                "uvicorn.access": {"level": log_level.upper(), "handlers": ["default"], "propagate": False},
                # App scopes
                "services.app": {"level": app_level, "handlers": ["default"], "propagate": False},
                "services.app.analyzer": {"level": app_level, "handlers": ["default"], "propagate": False},
                "services.app.anonymizer": {"level": app_level, "handlers": ["default"], "propagate": False},
                "services.app.llm_client": {"level": app_level, "handlers": ["default"], "propagate": False},
                # Third-party
                "presidio": {"level": pres_level, "handlers": ["default"], "propagate": False},
                "presidio-analyzer": {"level": pres_level, "handlers": ["default"], "propagate": False},
                "presidio-anonymizer": {"level": pres_level, "handlers": ["default"], "propagate": False},
                "LiteLLM": {"level": llm_level, "handlers": ["default"], "propagate": False},
                "httpx": {"level": llm_level, "handlers": ["default"], "propagate": False},
            },
        }
        with open(logcfg_path, 'w', encoding='utf-8') as f:
            json.dump(logcfg, f)
        log_config_arg = f" --log-config {shlex.quote(logcfg_path)}"
    except Exception:
        log_config_arg = ""
    cmd = f"{sys.executable} -m uvicorn services.app.main:app --host 127.0.0.1 --port {port} --log-level {log_level}{log_config_arg}"
    log_dest = _get_effective_with_env(getattr(args, 'log_dest', None), ['AIFW_LOG_DEST'], cfg.get('log_dest'), 'file')
    # Prepare server-side env for monthly cleanup BEFORE launch
    base_log = _get_effective_with_env(getattr(args, 'log_file', None), ['AIFW_LOG_FILE'], cfg.get('log_file'), os.path.join(work_dir, f"aifw-server-{port}.log"))
    months_to_keep = int(_get_effective_with_env(None, ['AIFW_LOG_MONTHS_TO_KEEP'], cfg.get('log_months_to_keep'), 6) or 6)
    env["AIFW_LOG_FILE"] = os.path.abspath(os.path.expanduser(base_log))
    env["AIFW_LOG_MONTHS_TO_KEEP"] = str(months_to_keep)
    if log_dest == 'stdout':
        # Background process, inherit stdout/stderr so logs appear in terminal, but CLI exits
        proc = subprocess.Popen(
            shlex.split(cmd),
            env=env,
            stdout=None,
            stderr=None,
            preexec_fn=os.setsid,
            close_fds=False,
            cwd=PROJECT_ROOT,
        )
        pidfile = _write_pidfile_with_fallbacks(work_dir, port, proc.pid)
        time.sleep(0.3)
        print(f"aifw is running at http://localhost:{port}.")
        if not pidfile:
            print("warning: failed to write pidfile (try --work-dir ~/.aifw or set AIFW_WORK_DIR)")
        return 0
    else:
        # Background to file
        log_file = _monthly_log_path(base_log)
        try:
            os.makedirs(os.path.dirname(log_file), exist_ok=True)
            log_fh = open(log_file, 'ab', buffering=0)
            proc = subprocess.Popen(
                shlex.split(cmd),
                env=env,
                stdout=log_fh,
                stderr=subprocess.STDOUT,
                preexec_fn=os.setsid,
                close_fds=True,
                cwd=PROJECT_ROOT,
            )
            # Cleanup old logs
            cleanup_monthly_logs(base_log, months_to_keep)
        except Exception:
            # Fallback to stdout if file cannot be used
            proc = subprocess.Popen(
                shlex.split(cmd),
                env=env,
                stdout=None,
                stderr=None,
                preexec_fn=os.setsid,
                close_fds=False,
                cwd=PROJECT_ROOT,
            )
        # Write pidfile under work_dir (with fallback)
        pidfile = _write_pidfile_with_fallbacks(work_dir, port, proc.pid)
        time.sleep(0.6)
        print(f"aifw is running at http://localhost:{port}.")
        print(f"logs: {log_file}")
        if not pidfile:
            print("warning: failed to write pidfile (try --work-dir ~/.aifw or set AIFW_WORK_DIR)")
        return 0


def cmd_http_call(args: argparse.Namespace) -> int:
    # Load config
    cfg, _ = _find_and_load_config(getattr(args, 'config', None), getattr(args, 'work_dir', None))
    text = read_stdin_if_dash(args.text)
    api_key_file = _get_effective_with_env(getattr(args, 'api_key_file', None), ['AIFW_API_KEY_FILE'], cfg.get('api_key_file'), None)
    api_key_file = os.path.abspath(api_key_file) if api_key_file else None
    payload = {
        "text": text,
        "apiKeyFile": api_key_file,
        "model": None,
        "temperature": float(_get_effective_with_env(getattr(args, 'temperature', None), ['AIFW_TEMPERATURE'], cfg.get('temperature'), 0.0) or 0.0),
    }
    data = json.dumps(payload).encode('utf-8')
    # Derive URL from port (priority: CLI > env > config > default)
    call_port = int(_get_effective_with_env(getattr(args, 'port', None), ['AIFW_PORT'], cfg.get('port'), 8844) or 8844)
    url = f"http://localhost:{call_port}/api/call"
    headers = _build_headers({'Content-Type': 'application/json'}, cfg, args)
    req = urllib.request.Request(url, data=data, headers=headers)
    try:
        with urllib.request.urlopen(req) as resp:
            body = resp.read().decode('utf-8')
            try:
                j = json.loads(body)
                err = j.get('error')
                if err:
                    print(f"error: {err}", file=sys.stderr)
                    return 2
                out = (j.get('output') or {}).get('text', '')
                print(out)
            except Exception:
                print(body)
        return 0
    except urllib.error.HTTPError as e:
        try:
            err_body = e.read().decode('utf-8', errors='ignore')
        except Exception:
            err_body = ''
        reason = getattr(e, 'reason', '') or ''
        where = getattr(e, 'url', url)
        prefix = f"HTTP {getattr(e, 'code', '')} {reason} for {where}".strip()
        if err_body:
            # Try to pretty print JSON error
            try:
                j = json.loads(err_body)
                print(f"{prefix}: {json.dumps(j, ensure_ascii=False)}", file=sys.stderr)
            except Exception:
                print(f"{prefix}: {err_body}", file=sys.stderr)
        else:
            print(f"{prefix}: (empty body)", file=sys.stderr)
        return 2
    except urllib.error.URLError as e:
        reason = getattr(e, 'reason', e)
        print(f"Connection error: {reason}", file=sys.stderr)
        return 3


def cmd_mask_restore(args: argparse.Namespace) -> int:
    # Load config
    cfg, _ = _find_and_load_config(getattr(args, 'config', None), getattr(args, 'work_dir', None))
    text = read_stdin_if_dash(args.text)
    language = getattr(args, 'language', None)
    # Resolve port
    port = int(_get_effective_with_env(getattr(args, 'port', None), ['AIFW_PORT'], cfg.get('port'), 8844) or 8844)

    # 1) mask_text → JSON response { output: { text, maskMeta }, error }
    url_mask = f"http://localhost:{port}/api/mask_text"
    payload_mask = {"text": text, "language": language}
    data_mask = json.dumps(payload_mask, ensure_ascii=False).encode('utf-8')
    headers = _build_headers({'Content-Type': 'application/json'}, cfg, args)
    req_mask = urllib.request.Request(url_mask, data=data_mask, headers=headers)
    try:
        with urllib.request.urlopen(req_mask) as resp:
            body = resp.read().decode('utf-8', errors='replace')
            j = json.loads(body)
            if j.get('error'):
                print(f"error: {j['error']}", file=sys.stderr)
                return 2
            output = j.get('output') or {}
            masked_text = output.get('text', '')
            mask_meta = output.get('maskMeta', '')
            print(masked_text)
    except urllib.error.HTTPError as e:
        try:
            err_body = e.read().decode('utf-8', errors='ignore')
        except Exception:
            err_body = ''
        print(f"HTTP {getattr(e, 'code', '')} for {getattr(e, 'url', url_mask)}: {err_body}", file=sys.stderr)
        return 2
    except Exception as e:
        print(f"mask_text failed: {e}", file=sys.stderr)
        return 3

    # 2) restore_text → JSON request { text, maskMeta }, JSON response { output: { text }, error }
    url_restore = f"http://localhost:{port}/api/restore_text"
    payload_restore = {"text": masked_text, "maskMeta": mask_meta}
    data_restore = json.dumps(payload_restore, ensure_ascii=False).encode('utf-8')
    headers = _build_headers({'Content-Type': 'application/json'}, cfg, args)
    req_restore = urllib.request.Request(url_restore, data=data_restore, headers=headers)
    try:
        with urllib.request.urlopen(req_restore) as resp:
            body = resp.read().decode('utf-8', errors='replace')
            j = json.loads(body)
            if j.get('error'):
                print(f"error: {j['error']}", file=sys.stderr)
                return 2
            restored_text = (j.get('output') or {}).get('text', body)
            print(restored_text)
        return 0
    except urllib.error.HTTPError as e:
        try:
            err_body = e.read().decode('utf-8', errors='ignore')
        except Exception:
            err_body = ''
        print(f"HTTP {getattr(e, 'code', '')} for {getattr(e, 'url', url_restore)}: {err_body}", file=sys.stderr)
        return 2
    except Exception as e:
        print(f"restore_text failed: {e}", file=sys.stderr)
        return 3


def cmd_mask_restore_batch(args: argparse.Namespace) -> int:
    cfg, _ = _find_and_load_config(getattr(args, 'config', None), getattr(args, 'work_dir', None))
    language = getattr(args, 'language', None)
    raw_texts = list(getattr(args, 'texts', []) or [])
    texts: list[str] = [read_stdin_if_dash(t) for t in raw_texts]
    if not texts:
        print("no input texts", file=sys.stderr)
        return 2
    port = int(_get_effective_with_env(getattr(args, 'port', None), ['AIFW_PORT'], cfg.get('port'), 8844) or 8844)

    # mask_text_batch
    url_mask = f"http://localhost:{port}/api/mask_text_batch"
    payload = [{"text": t, "language": language} for t in texts]
    data = json.dumps(payload, ensure_ascii=False).encode('utf-8')
    headers = _build_headers({'Content-Type': 'application/json'}, cfg, args)
    req = urllib.request.Request(url_mask, data=data, headers=headers)
    try:
        with urllib.request.urlopen(req) as resp:
            body = resp.read().decode('utf-8', errors='replace')
            j = json.loads(body)
            if j.get('error'):
                print(f"error: {j['error']}", file=sys.stderr)
                return 2
            arr = list((j.get('output') or []))
            if len(arr) != len(texts):
                print("mask_text_batch: response length mismatch", file=sys.stderr)
                return 2
            masked = [it.get('text', '') for it in arr]
            metas = [it.get('maskMeta', '') for it in arr]
            for m in masked:
                print(m)
    except Exception as e:
        print(f"mask_text_batch failed: {e}", file=sys.stderr)
        return 3

    # restore_text_batch
    url_restore = f"http://localhost:{port}/api/restore_text_batch"
    restore_payload = [{"text": m, "maskMeta": mm} for m, mm in zip(masked, metas)]
    data2 = json.dumps(restore_payload, ensure_ascii=False).encode('utf-8')
    headers = _build_headers({'Content-Type': 'application/json'}, cfg, args)
    req2 = urllib.request.Request(url_restore, data=data2, headers=headers)
    try:
        with urllib.request.urlopen(req2) as resp:
            body = resp.read().decode('utf-8', errors='replace')
            j = json.loads(body)
            if j.get('error'):
                print(f"error: {j['error']}", file=sys.stderr)
                return 2
            restored = list((j.get('output') or []))
            for r in restored:
                print((r or {}).get('text', ''))
        return 0
    except Exception as e:
        print(f"restore_text_batch failed: {e}", file=sys.stderr)
        return 3


def cmd_multi_mask_one_restore(args: argparse.Namespace) -> int:
    cfg, _ = _find_and_load_config(getattr(args, 'config', None), getattr(args, 'work_dir', None))
    language = getattr(args, 'language', None)
    raw_texts = list(getattr(args, 'texts', []) or [])
    texts: list[str] = [read_stdin_if_dash(t) for t in raw_texts]
    if not texts:
        print("no input texts", file=sys.stderr)
        return 2
    port = int(_get_effective_with_env(getattr(args, 'port', None), ['AIFW_PORT'], cfg.get('port'), 8844) or 8844)

    masked: list[str] = []
    metas: list[str] = []
    restore_payload: list[dict] = []

    # multiple mask_text
    for t in texts:
        url_mask = f"http://localhost:{port}/api/mask_text"
        payload = {"text": t, "language": language}
        data = json.dumps(payload, ensure_ascii=False).encode('utf-8')
        headers = _build_headers({'Content-Type': 'application/json'}, cfg, args)
        req = urllib.request.Request(url_mask, data=data, headers=headers)
        with urllib.request.urlopen(req) as resp:
            body = resp.read().decode('utf-8', errors='replace')
            j = json.loads(body)
            if j.get('error'):
                print(f"error: {j['error']}", file=sys.stderr)
                return 2
            output = j.get('output') or {}
            masked_text = output.get('text', '')
            mask_meta = output.get('maskMeta', '')
            restore_payload.append({"text": masked_text, "maskMeta": mask_meta})
            print(masked_text)

    # single restore_text_batch
    url_restore = f"http://localhost:{port}/api/restore_text_batch"
    data2 = json.dumps(restore_payload, ensure_ascii=False).encode('utf-8')
    headers = _build_headers({'Content-Type': 'application/json'}, cfg, args)
    req2 = urllib.request.Request(url_restore, data=data2, headers=headers)
    with urllib.request.urlopen(req2) as resp:
        body = resp.read().decode('utf-8', errors='replace')
        j = json.loads(body)
        if j.get('error'):
            print(f"error: {j['error']}", file=sys.stderr)
            return 2
        restored = list((j.get('output') or []))
        for r in restored:
            print((r or {}).get('text', ''))
    return 0


# stop: stop backend
def cmd_stop(args: argparse.Namespace) -> int:
    port = args.port
    # Search for pidfile across possible locations
    candidates = []
    wd_arg = getattr(args, 'work_dir', None)
    if wd_arg:
        candidates.append(resolve_work_dir(wd_arg))
    env_wd = os.environ.get("AIFW_WORK_DIR")
    if env_wd:
        candidates.append(env_wd)
    candidates.append(os.path.expanduser("~/.aifw"))

    pidfile = None
    for base in candidates:
        pf = os.path.join(base, f"aifw-server-{port}.pid")
        if os.path.exists(pf):
            pidfile = pf
            break
    if not pidfile:
        print("No running server found.")
        return 0

    try:
        with open(pidfile, 'r') as f:
            pid_txt = f.read().strip()
        pid = int(pid_txt)
    except Exception:
        try:
            os.remove(pidfile)
        except Exception:
            pass
        print("No running server found.")
        return 0

    # Try graceful termination of the whole process group
    try:
        os.killpg(pid, signal.SIGTERM)
    except Exception:
        try:
            os.kill(pid, signal.SIGTERM)
        except Exception:
            pass
    # Wait up to ~5 seconds
    deadline = time.time() + 5.0
    while time.time() < deadline:
        try:
            os.kill(pid, 0)
            time.sleep(0.2)
        except OSError:
            break
    else:
        # Force kill
        try:
            os.killpg(pid, signal.SIGKILL)
        except Exception:
            try:
                os.kill(pid, signal.SIGKILL)
            except Exception:
                pass
    try:
        os.remove(pidfile)
    except Exception:
        pass
    print("aifw stopped.")
    return 0

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="aifw", description="OneAIFW CLI")
    sub = parser.add_subparsers(dest="command", required=True)

    # direct_call: in-process
    p_direct = sub.add_parser("direct_call", help="In-process call (anonymize→LLM→restore)")
    p_direct.add_argument("text", help="Text to send or '-' to read from stdin")
    p_direct.add_argument("--model", help="LiteLLM model name (e.g., gpt-4o-mini, glm-4)")
    p_direct.add_argument("--temperature", type=float, default=0.0)
    p_direct.add_argument("--stage", choices=["restored", "anonymized", "anonymized_via_llm"], default="restored",
                          help="Output stage: final restored (default), anonymized only, or anonymized sent via LLM (echo)")
    p_direct.add_argument("--api-key-file", help="Path to JSON config with openai-api-key/base-url/model")
    p_direct.add_argument("--config", help="Path to aifw config file (json/yaml)")
    p_direct.add_argument("--work-dir", help="Base dir for config/logs (default ~/.aifw or $AIFW_WORK_DIR)")
    p_direct.add_argument("--state-dir", help="[deprecated] Same as --work-dir")
    p_direct.add_argument("--log-dest", choices=["stdout","file"], default="file")
    p_direct.add_argument("--log-file", help="Log file path if --log-dest=file")
    p_direct.add_argument("--log-level", choices=["DEBUG","INFO","WARNING","ERROR"], default="INFO")
    p_direct.add_argument("--log-scopes", help="Comma-separated: app,uvicorn,presidio,litellm,all (default app,uvicorn)")
    p_direct.set_defaults(func=cmd_direct_call)

    # launch: start FastAPI backend
    p_launch = sub.add_parser("launch", help="Start HTTP service (FastAPI)")
    p_launch.add_argument("--config", help="Path to aifw config file (json/yaml)")
    p_launch.add_argument("--api-key-file", help="Default API key file for backend (env: AIFW_API_KEY_FILE)")
    p_launch.add_argument("--port", type=int, default=8844)
    p_launch.add_argument("--http-api-key", help="HTTP API key for backend auth (env: AIFW_HTTP_API_KEY)")
    p_launch.add_argument("--work-dir", help="Base dir for config/logs/pid (default ~/.aifw or $AIFW_WORK_DIR)")
    p_launch.add_argument("--state-dir", help="[deprecated] Same as --work-dir")
    p_launch.add_argument("--log-dest", choices=["stdout","file"], default="file")
    p_launch.add_argument("--log-file", help="Log file path if --log-dest=file")
    p_launch.add_argument("--log-level", choices=["DEBUG","INFO","WARNING","ERROR"], default="INFO")
    p_launch.add_argument("--log-scopes", help="Comma-separated: app,uvicorn,presidio,litellm,all (default app,uvicorn)")
    p_launch.set_defaults(func=cmd_launch)

    p_stop = sub.add_parser("stop", help="Stop HTTP service started by launch")
    p_stop.add_argument("--config", help="Path to aifw config file (json/yaml)")
    p_stop.add_argument("--port", type=int, default=8844)
    p_stop.add_argument("--work-dir", help="Base dir for pid/logs (default ~/.aifw or $AIFW_WORK_DIR)")
    p_stop.add_argument("--state-dir", help="[deprecated] Same as --work-dir")
    p_stop.set_defaults(func=cmd_stop)

    # call: HTTP mode
    p_http = sub.add_parser("call", help="Call HTTP API /api/call")
    p_http.add_argument("text", help="Text to send or '-' to read from stdin")
    p_http.add_argument("--config", help="Path to aifw config file (json/yaml)")
    p_http.add_argument("--api-key-file", help="Key file path passed to backend (optional)")
    p_http.add_argument("--temperature", type=float)
    p_http.add_argument("--http-api-key", help="HTTP API key for Authorization header (env: AIFW_HTTP_API_KEY)")
    p_http.set_defaults(func=cmd_http_call)

    # mask_restore: test mask_text and restore_text HTTP APIs
    p_mr = sub.add_parser("mask_restore", help="Call HTTP API: /api/mask_text then /api/restore_text")
    p_mr.add_argument("text", help="Text to send or '-' to read from stdin")
    p_mr.add_argument("--language", help="Optional language hint (e.g., en, zh)")
    p_mr.add_argument("--config", help="Path to aifw config file (json/yaml)")
    p_mr.add_argument("--port", type=int, default=8844)
    p_mr.add_argument("--work-dir", help="Base dir for config/logs (default ~/.aifw or $AIFW_WORK_DIR)")
    p_mr.add_argument("--http-api-key", help="HTTP API key for Authorization header (env: AIFW_HTTP_API_KEY)")
    p_mr.set_defaults(func=cmd_mask_restore)

    # mask_restore_batch
    p_mrb = sub.add_parser("mask_restore_batch", help="Batch call /api/mask_text_batch then /api/restore_text_batch")
    p_mrb.add_argument("texts", nargs='+', help="One or more texts; use '-' to read from stdin as a single item")
    p_mrb.add_argument("--language", help="Optional language hint (e.g., en, zh)")
    p_mrb.add_argument("--config", help="Path to aifw config file (json/yaml)")
    p_mrb.add_argument("--port", type=int, default=8844)
    p_mrb.add_argument("--work-dir", help="Base dir for config/logs (default ~/.aifw or $AIFW_WORK_DIR)")
    p_mrb.add_argument("--http-api-key", help="HTTP API key for Authorization header (env: AIFW_HTTP_API_KEY)")
    p_mrb.set_defaults(func=cmd_mask_restore_batch)

    # multi_mask_one_restore
    p_mmr = sub.add_parser("multi_mask_one_restore", help="Mask each text individually, then restore all via restore_text_batch")
    p_mmr.add_argument("texts", nargs='+', help="One or more texts; use '-' to read from stdin as a single item")
    p_mmr.add_argument("--language", help="Optional language hint (e.g., en, zh)")
    p_mmr.add_argument("--config", help="Path to aifw config file (json/yaml)")
    p_mmr.add_argument("--port", type=int, default=8844)
    p_mmr.add_argument("--work-dir", help="Base dir for config/logs (default ~/.aifw or $AIFW_WORK_DIR)")
    p_mmr.add_argument("--http-api-key", help="HTTP API key for Authorization header (env: AIFW_HTTP_API_KEY)")
    p_mmr.set_defaults(func=cmd_multi_mask_one_restore)

    return parser


def main(argv=None) -> int:
    argv = argv if argv is not None else sys.argv[1:]
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
