#!/usr/bin/env python3
"""Package reviewed local engine bytes, without installing or fetching anything."""
import hashlib
import json
import shutil
import sys
from pathlib import Path

PIN = "cc0d28914306140c593351636401884ea5e4f1c9"
FILES = {
    "grapheine.py": "201d2207a4b0caad5a53818c36e874c8ad5e5e6d5aa54370c1be1ee3721b8451",
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
