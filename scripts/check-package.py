#!/usr/bin/env python3
"""Exercise the packaged engine with no developer tools or user Python setup."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def check(app):
    app = app.resolve(strict=True)
    contents = app / "Contents"
    python = contents / "Frameworks/Python.framework/Versions/Current/bin/python3.13"
    helper = contents / "Resources/Grapheine/bridge.py"
    engine = helper.parent / "engine"
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    with tempfile.TemporaryDirectory(prefix="planisphere-package-", dir="/private/tmp") as temporary:
        root = Path(temporary)
        home = root / "home"
        home.mkdir()
        vault = root / "vault"
        (vault / "Archive").mkdir(parents=True)
        (vault / "Status.md").write_text("# Current\nSee [[Archive/Status]].\n", encoding="utf-8")
        (vault / "Archive/Status.md").write_text("# Earlier\n", encoding="utf-8")
        original = {str(path.relative_to(vault)): hashlib.sha256(path.read_bytes()).hexdigest()
                    for path in vault.rglob("*") if path.is_file()}
        env = {"HOME": str(home), "PATH": "/no-developer-tools", "TMPDIR": temporary,
               "PYTHONHOME": "/invalid-host-runtime", "PYTHONPATH": "/invalid-host-modules"}
        def run(arguments):
            result = subprocess.run([str(python), "-B", "-s", "-E", "-X", "utf8", *arguments],
                                    env=env, cwd=temporary, capture_output=True, text=True, timeout=60)
            if result.returncode:
                raise RuntimeError(result.stdout + result.stderr)
            return json.loads(result.stdout)
        runtime = run(["-c", "import sys,json,ssl,sqlite3,ctypes,lzma; print(json.dumps({'prefix':sys.prefix,'version':sys.version.split()[0]}))"])
        if not Path(runtime["prefix"]).resolve().is_relative_to(contents):
            raise RuntimeError("Python loaded a runtime outside the app.")
        scan = run([str(helper), "scan", "--engine-root", str(engine), "--vault", str(vault)])
        graph = run([str(helper), "graph", "--engine-root", str(engine), "--vault", str(vault)])
        if scan.get("notes") != 2 or len(scan.get("groups", [])) != 1:
            raise RuntimeError("Packaged discovery did not find the fixture notes and duplicate group.")
        if len(graph.get("nodes", [])) != 2 or len(graph.get("edges", [])) != 1:
            raise RuntimeError("Packaged graph did not return the fixture relationship.")
        after = {str(path.relative_to(vault)): hashlib.sha256(path.read_bytes()).hexdigest()
                 for path in vault.rglob("*") if path.is_file()}
        if after != original or (vault / ".git").exists():
            raise RuntimeError("Packaged read operations changed the fixture vault.")
        print(json.dumps({"signature": "valid", "runtime": runtime["version"],
                          "externalPython": False, "notes": scan["notes"],
                          "edges": len(graph["edges"]), "vaultUnchanged": True}))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: check-package.py Planisphere.app")
    check(Path(sys.argv[1]))
