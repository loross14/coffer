#!/usr/bin/env python3
"""Manual adapter tests. No live hook installation, model loading, or training."""
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import selectors
import resource
import signal
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

LIMIT = 262144
ACTIVE = None


def stop_child():
    global ACTIVE
    if ACTIVE is not None:
        try:
            os.killpg(ACTIVE.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        ACTIVE.wait(timeout=3)
        ACTIVE = None


def cancelled(*_):
    stop_child()
    raise InterruptedError("Test canceled. A model server may continue work after disconnection.")


def bounded_text(value, label, maximum=65536):
    if not isinstance(value, str) or len(value.encode()) > maximum or "\x00" in value:
        raise ValueError(label + " is missing or too large.")
    return value


def fixture(request):
    host = request.get("host")
    if host not in {"codex", "claude"}:
        raise ValueError("Choose Codex or Claude Code.")
    payload = json.loads(bounded_text(request.get("input"), "Event JSON"))
    if not isinstance(payload, dict):
        raise ValueError("Event input must be a JSON object.")
    session = bounded_text(payload.get("session_id"), "session_id", 1024)
    cwd = bounded_text(payload.get("cwd"), "cwd", 4096)
    if not session or not cwd.startswith("/"):
        raise ValueError("Use a nonempty session_id and an absolute cwd.")
    event = bounded_text(payload.get("hook_event_name", "UserPromptSubmit"), "hook_event_name", 128)
    return {"host": host, "event": event, "session_id": session, "cwd": cwd,
            "keys": sorted(payload), "input_bytes": len(request["input"].encode()),
            "coverage": "Event-envelope check only. No hook ran and no host accepted or installed this fixture."}


def limit_child():
    resource.setrlimit(resource.RLIMIT_FSIZE, (8388608, 8388608))
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def execute(request):
    global ACTIVE
    executable = Path(bounded_text(request.get("executable"), "Executable", 4096)).resolve(strict=True)
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise ValueError("Choose an executable file. Scripts need an executable permission and a shebang.")
    args = request.get("arguments", [])
    if not isinstance(args, list) or len(args) > 32:
        raise ValueError("Arguments must be a JSON array with at most 32 strings.")
    args = [bounded_text(a, "Argument", 4096) for a in args]
    payload = bounded_text(request.get("input", ""), "Input")
    timeout = request.get("timeout", 15)
    if type(timeout) is not int or not 1 <= timeout <= 30:
        raise ValueError("Choose a timeout from 1 to 30 seconds.")
    if not Path("/usr/bin/sandbox-exec").is_file():
        raise ValueError("This Mac cannot provide the required execution sandbox. The adapter was not run.")
    with tempfile.TemporaryDirectory(prefix="planisphere-adapter-") as temporary:
        root = Path(temporary).resolve()
        home = root / "home"
        home.mkdir(mode=0o700)
        input_file = root / "input.json"
        input_file.write_text(payload)
        # Only this run directory is writable. Home/vault content and networking
        # stay denied. Read access is limited to system runtimes and the exact executable.
        readable = ["/System/Library", "/System/Volumes/Preboot", "/private/preboot/Cryptexes/OS", "/usr/bin", "/usr/lib", "/usr/share", "/bin", "/sbin", "/Library/Apple", "/Library/Developer", "/Applications/Xcode.app"]
        literals = ["/", "/private/etc", str(executable), "/dev/null", "/dev/urandom", "/dev/random", "/private/etc/localtime"]
        profile = '(version 1) (deny default) (allow process-exec) (allow process-fork) (allow sysctl-read) (allow file-read-metadata)\n'
        profile += '(allow file-read* ' + ' '.join('(subpath ' + json.dumps(p) + ')' for p in readable) + ')\n'
        profile += '(allow file-read* ' + ' '.join('(literal ' + json.dumps(p) + ')' for p in literals) + ')\n'
        profile += '(allow file-read* file-write* (subpath ' + json.dumps(str(root)) + '))\n'
        env = {"HOME": str(home), "TMPDIR": str(root), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
               "LANG": "en_US.UTF-8", "PLANISPHERE_ADAPTER_TEST": "1"}
        output = {"stdout": bytearray(), "stderr": bytearray()}
        outcome = "completed"
        start = time.monotonic()
        try:
            with input_file.open("rb") as source:
                ACTIVE = subprocess.Popen(["/usr/bin/sandbox-exec", "-p", profile, str(executable), *args],
                                          stdin=source, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                          cwd=root, env=env, start_new_session=True, preexec_fn=limit_child)
            child = ACTIVE
            with selectors.DefaultSelector() as selector:
                selector.register(child.stdout, selectors.EVENT_READ, "stdout")
                selector.register(child.stderr, selectors.EVENT_READ, "stderr")
                while selector.get_map():
                    if time.monotonic() - start > timeout:
                        outcome = "timed_out"
                        break
                    for key, _ in selector.select(timeout=0.05):
                        chunk = os.read(key.fileobj.fileno(), 8192)
                        if not chunk:
                            selector.unregister(key.fileobj)
                        else:
                            room = LIMIT - sum(len(v) for v in output.values())
                            output[key.data].extend(chunk[:max(0, room)])
                            if len(chunk) > room:
                                outcome = "output_limit"
                                break
                    if outcome != "completed":
                        break
                if outcome == "completed":
                    try:
                        code = child.wait(timeout=max(0.01, timeout - (time.monotonic() - start)))
                    except subprocess.TimeoutExpired:
                        outcome = "timed_out"
                        code = None
                else:
                    code = None
            # Kill any descendants remaining in the run's process group, even
            # if the executable exited successfully but left a background child.
            stop_child()
            for stream in (child.stdout, child.stderr):
                stream.close()
            return {"outcome": outcome, "exit_code": code, "elapsed_seconds": round(time.monotonic() - start, 3),
                    **{k: bytes(v).decode("utf-8", errors="replace") for k, v in output.items()},
                    "executable_sha256": hashlib.sha256(executable.read_bytes()).hexdigest() if executable.stat().st_size <= 33554432 else None,
                    "coverage": "Disposable folder; no inherited credentials; network and home/vault content denied. This is an OS process sandbox, not a virtual machine. No live hooks were changed."}
        finally:
            stop_child()


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise ValueError("Redirect refused. Use the exact local server address.")


def endpoint(value):
    url = urllib.parse.urlsplit(bounded_text(value, "Server URL", 2048))
    try:
        address = ipaddress.ip_address(url.hostname or "")
        port = url.port
    except ValueError:
        raise ValueError("Use a literal loopback address, such as http://127.0.0.1:41234.") from None
    if not address.is_loopback or url.scheme not in {"http", "https"} or url.username or url.password or url.query or url.fragment or url.path.rstrip("/") not in {"", "/v1"}:
        raise ValueError("Use a loopback HTTP(S) server with no credentials, query, or custom path in its URL.")
    if port is not None and port < 1:
        raise ValueError("Invalid server port.")
    return urllib.parse.urlunsplit((url.scheme, url.netloc, "/v1", "", ""))


def http_json(base, path, token="", body=None):
    headers = {"Content-Type": "application/json"}
    if token:
        if "\r" in token or "\n" in token:
            raise ValueError("Invalid server token.")
        headers["Authorization"] = "Bearer " + token
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(base + path, data=data, headers=headers)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    try:
        with opener.open(request, timeout=30) as response:
            content = response.read(LIMIT + 1)
    except urllib.error.HTTPError as error:
        raise ValueError("Server returned HTTP " + str(error.code) + ". Check its address, authentication and model configuration.") from None
    if len(content) > LIMIT:
        raise ValueError("Server response exceeded 256 KiB.")
    return json.loads(content)


def model_test(request):
    base = endpoint(request.get("endpoint"))
    token = bounded_text(request.get("token", ""), "Server token", 8192)
    inventory = http_json(base, "/models", token)
    rows = inventory.get("data") if isinstance(inventory, dict) else None
    if not isinstance(rows, list) or len(rows) > 1000:
        raise ValueError("Server returned an invalid model inventory.")
    models = sorted({v["id"] for v in rows if isinstance(v, dict) and isinstance(v.get("id"), str) and len(v["id"]) <= 1024})
    if request["action"] == "models":
        return {"models": models, "coverage": "Server-advertised model IDs. Visibility does not prove weights are loaded, a LoRA is attached, or inference is device-local."}
    model = bounded_text(request.get("model"), "Model", 1024)
    if model not in models:
        raise ValueError("The selected model is no longer in this server's inventory. Refresh models.")
    prompt = bounded_text(request.get("input"), "Prompt")
    if not prompt.strip():
        raise ValueError("Enter a test prompt.")
    limit = request.get("max_tokens", 256)
    if type(limit) is not int or not 1 <= limit <= 2048:
        raise ValueError("Choose an output limit from 1 to 2048 tokens.")
    start = time.monotonic()
    result = http_json(base, "/chat/completions", token, {"model": model, "messages": [{"role": "user", "content": prompt}], "max_tokens": limit, "temperature": 0, "stream": False})
    if not isinstance(result, dict) or result.get("model") != model:
        raise ValueError("Server response did not identify the selected model. Its output is not accepted as an adapter test.")
    choices = result.get("choices")
    if not isinstance(choices, list) or len(choices) != 1 or not isinstance(choices[0], dict):
        raise ValueError("Server returned an invalid completion.")
    choice = choices[0]
    message = choice.get("message")
    if not isinstance(message, dict) or not isinstance(message.get("content"), str):
        raise ValueError("Server did not return text output.")
    if choice.get("finish_reason") not in {"stop", "length"}:
        raise ValueError("Server did not finish the test normally.")
    return {"model": model, "output": message["content"], "finish_reason": choice.get("finish_reason"),
            "usage": result.get("usage"), "elapsed_seconds": round(time.monotonic() - start, 3),
            "coverage": "Only the entered prompt was sent. Usage is server-reported; missing usage is unknown. The server owns model/LoRA loading and may forward requests. No weights, training or live support settings were changed."}


def main():
    signal.signal(signal.SIGTERM, cancelled)
    signal.signal(signal.SIGINT, cancelled)
    def deadline(*_):
        stop_child()
        raise TimeoutError("Test reached its 35-second deadline. Server generation may continue after disconnect.")
    signal.signal(signal.SIGALRM, deadline)
    signal.setitimer(signal.ITIMER_REAL, 35)
    try:
        data = sys.stdin.buffer.read(LIMIT + 1)
        if len(data) > LIMIT:
            raise ValueError("Request exceeds 256 KiB.")
        request = json.loads(data)
        if not isinstance(request, dict):
            raise ValueError("Request must be an object.")
        action = request.get("action")
        if action == "fixture":
            result = fixture(request)
        elif action == "execute":
            result = execute(request)
        elif action in {"models", "model"}:
            result = model_test(request)
        else:
            raise ValueError("Unknown test action.")
        print(json.dumps({"ok": True, "result": result}))
    except Exception as error:
        print(json.dumps({"ok": False, "error": str(error)[:2000]}))
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        stop_child()


if __name__ == "__main__":
    main()
