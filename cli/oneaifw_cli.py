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


def read_stdin_if_dash(value: str) -> str:
    if value == "-":
        return sys.stdin.read()
    return value


def resolve_state_dir(provided: str | None) -> str:
    base = provided or os.environ.get("AIFW_STATE_DIR")
    if not base:
        base = os.path.expanduser("~/.aifw")
    try:
        os.makedirs(base, exist_ok=True)
    except Exception:
        pass
    return base


def _pidfile_candidates(port: int, state_dir_arg: str | None) -> list[str]:
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
    if state_dir_arg:
        _add(resolve_state_dir(state_dir_arg))
    # 2) environment directory
    _add(os.environ.get("AIFW_STATE_DIR"))
    # 3) default home directory
    _add("~/.aifw")

    return [os.path.join(b, f"aifw-server-{port}.pid") for b in bases]


def _find_existing_pidfile(port: int, state_dir_arg: str | None) -> str | None:
    for pf in _pidfile_candidates(port, state_dir_arg):
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
    # Configure logging destination and level for in-process run
    level = getattr(logging, (args.log_level or 'INFO').upper(), logging.INFO)
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
    handler: logging.Handler
    if args.log_dest == 'file':
        state_dir = resolve_state_dir(getattr(args, 'state_dir', None))
        log_file = args.log_file or os.path.join(state_dir, 'aifw-direct.log')
        os.makedirs(os.path.dirname(log_file), exist_ok=True)
        handler = logging.FileHandler(log_file)
    else:
        handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(logging.Formatter("%(asctime)s [%(levelname)s] %(name)s: %(message)s"))
    logging.getLogger('services.app').addHandler(handler)

    text = read_stdin_if_dash(args.text)
    api_key_file = os.path.abspath(args.api_key_file) if args.api_key_file else None
    output = local_api.call(
        text=text,
        api_key_file=api_key_file,
        model=args.model,
        temperature=args.temperature,
    )
    print(output)
    return 0


def cmd_launch(args: argparse.Namespace) -> int:
    # Launch FastAPI service using uvicorn in background
    port = args.port
    env = os.environ.copy()

    # Enforce global single instance per port: if running, report and exit
    if _server_alive_on_port(port):
        print(f"aifw is already running at http://localhost:{port} (health check passed).")
        return 1
    existing_pf = _find_existing_pidfile(port, getattr(args, 'state_dir', None))
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

    if args.api_key_file:
        env["ONEAIFW_DEFAULT_API_KEY_FILE"] = os.path.abspath(args.api_key_file)
    # Ensure backend package importable
    env["PYTHONPATH"] = (
        (PROJECT_ROOT + (os.pathsep + env.get("PYTHONPATH", "") if env.get("PYTHONPATH") else ""))
    )
    # Import path for app: services.app.main:app
    log_level = (args.log_level or 'info').lower()
    # Build uvicorn log-config to include root logger so app logs are captured
    state_dir = resolve_state_dir(getattr(args, 'state_dir', None))
    logcfg_path = os.path.join(state_dir, f"aifw-uvicorn-{port}.json")
    try:
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
            },
        }
        with open(logcfg_path, 'w', encoding='utf-8') as f:
            json.dump(logcfg, f)
        log_config_arg = f" --log-config {shlex.quote(logcfg_path)}"
    except Exception:
        log_config_arg = ""
    cmd = f"{sys.executable} -m uvicorn services.app.main:app --host 127.0.0.1 --port {port} --log-level {log_level}{log_config_arg}"
    if args.log_dest == 'stdout':
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
        pidfile = _write_pidfile_with_fallbacks(state_dir, port, proc.pid)
        time.sleep(0.3)
        print(f"aifw is running at http://localhost:{port}.")
        if pidfile:
            print(f"pidfile: {pidfile}")
        else:
            print("warning: failed to write pidfile (try --state-dir ~/.aifw or set AIFW_STATE_DIR)")
        return 0
    else:
        # Background to file
        log_file = args.log_file or os.path.join(state_dir, f"aifw-server-{port}.log")
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
        # Write pidfile under state_dir (with fallback)
        pidfile = _write_pidfile_with_fallbacks(state_dir, port, proc.pid)
        time.sleep(0.6)
        print(f"aifw is running at http://localhost:{port}.")
        print(f"logs: {log_file}")
        if pidfile:
            print(f"pidfile: {pidfile}")
        else:
            print("warning: failed to write pidfile (try --state-dir ~/.aifw or set AIFW_STATE_DIR)")
        return 0


def cmd_http_call(args: argparse.Namespace) -> int:
    text = read_stdin_if_dash(args.text)
    url = args.url.rstrip('/') + '/api/call'
    payload = {
        "text": text,
        "apiKeyFile": os.path.abspath(args.api_key_file) if args.api_key_file else None,
        "model": args.model,
        "temperature": args.temperature,
    }
    data = json.dumps(payload).encode('utf-8')
    req = urllib.request.Request(url, data=data, headers={'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req) as resp:
            body = resp.read().decode('utf-8')
            try:
                j = json.loads(body)
                print(j.get('text', body))
            except Exception:
                print(body)
        return 0
    except urllib.error.HTTPError as e:
        print(f"HTTP {e.code}: {e.read().decode(errors='ignore')}", file=sys.stderr)
        return 2
    except urllib.error.URLError as e:
        print(f"Connection error: {e}", file=sys.stderr)
        return 3


# stop: stop backend
def cmd_stop(args: argparse.Namespace) -> int:
    port = args.port
    # Search for pidfile across possible locations
    candidates = []
    if getattr(args, 'state_dir', None):
        candidates.append(resolve_state_dir(args.state_dir))
    env_dir = os.environ.get("AIFW_STATE_DIR")
    if env_dir:
        candidates.append(env_dir)
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
    p_direct.add_argument("--api-key-file", help="Path to JSON config with openai-api-key/base-url/model")
    p_direct.add_argument("--state-dir", help="Base dir for logs (default ~/.aifw or $AIFW_STATE_DIR)")
    p_direct.add_argument("--log-dest", choices=["stdout","file"], default="stdout")
    p_direct.add_argument("--log-file", help="Log file path if --log-dest=file")
    p_direct.add_argument("--log-level", choices=["DEBUG","INFO","WARNING","ERROR"], default="INFO")
    p_direct.set_defaults(func=cmd_direct_call)

    # launch: start FastAPI backend
    p_launch = sub.add_parser("launch", help="Start HTTP service (FastAPI)")
    p_launch.add_argument("--api-key-file", help="Default API key file for backend (env: ONEAIFW_DEFAULT_API_KEY_FILE)")
    p_launch.add_argument("--port", type=int, default=8844)
    p_launch.add_argument("--state-dir", help="Base dir for pid/logs (default ~/.aifw or $AIFW_STATE_DIR)")
    p_launch.add_argument("--log-dest", choices=["stdout","file"], default="stdout")
    p_launch.add_argument("--log-file", help="Log file path if --log-dest=file")
    p_launch.add_argument("--log-level", choices=["DEBUG","INFO","WARNING","ERROR"], default="INFO")
    p_launch.set_defaults(func=cmd_launch)

    p_stop = sub.add_parser("stop", help="Stop HTTP service started by launch")
    p_stop.add_argument("--port", type=int, default=8844)
    p_stop.add_argument("--state-dir", help="Base dir for pid/logs (default ~/.aifw or $AIFW_STATE_DIR)")
    p_stop.set_defaults(func=cmd_stop)

    # call: HTTP mode
    p_http = sub.add_parser("call", help="Call HTTP API /api/call")
    p_http.add_argument("text", help="Text to send or '-' to read from stdin")
    p_http.add_argument("--url", default="http://localhost:8844", help="Service base URL")
    p_http.add_argument("--api-key-file", help="Key file path passed to backend (optional)")
    p_http.add_argument("--model", help="LiteLLM model name")
    p_http.add_argument("--temperature", type=float, default=0.0)
    p_http.set_defaults(func=cmd_http_call)

    return parser


def main(argv=None) -> int:
    argv = argv if argv is not None else sys.argv[1:]
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
