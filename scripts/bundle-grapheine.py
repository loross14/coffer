#!/usr/bin/env python3
"""Package reviewed local engine bytes, without installing or fetching anything."""
import hashlib
import json
import shutil
import sys
from pathlib import Path

PIN = "79c6b457018bd0eba1c890311c0b8351b97ff041"
FILES = {
    "grapheine.py": "3ef2bfb3f458719bf0ffc040b8bb6ab74d6763d3de9a7d0579f956c58df4d99f",
    "grapheine_authority.py": "cc531bd2abc8c9a8e3174ed180aeb1269497d118366bb7985c51d6c866b097a4",
}

source, destination = map(Path, sys.argv[1:])
for name, expected in FILES.items():
    if hashlib.sha256((source / name).read_bytes()).hexdigest() != expected:
        raise SystemExit("Grapheine source differs from reviewed revision " + PIN + ": " + name)
destination.mkdir(parents=True, exist_ok=False)
for name in [*FILES, "LICENSE", "AUTHORITY.md"]:
    shutil.copyfile(source / name, destination / name)
(destination / "provenance.json").write_text(json.dumps({"revision": PIN, "files": FILES}, indent=2) + "\n")
