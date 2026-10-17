#!/usr/bin/env python3
"""Package reviewed local engine bytes, without installing or fetching anything."""
import hashlib
import json
import shutil
import sys
from pathlib import Path

PIN = "0c96ff9d4c9fbce0a275268d88299143d56292d4"
FILES = {
    "grapheine.py": "e7869174237f4aad02b0f4b1af40c46cc9f7a268f9cf8223decd23fb5743ec93",
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
