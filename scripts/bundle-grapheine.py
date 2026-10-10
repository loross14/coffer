#!/usr/bin/env python3
"""Package reviewed local engine bytes, without installing or fetching anything."""
import hashlib
import json
import shutil
import sys
from pathlib import Path

PIN = "6f15793669841400684dc0ed8606516021b0ad72"
FILES = {
    "grapheine.py": "ba72179e5bf54bd1f59fbb2ac98c1591cdedc52bc948c4f4327c98b38cb0fce2",
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
