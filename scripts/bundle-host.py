#!/usr/bin/env python3
"""Bundle the reviewed, hash-pinned host runtime without network access."""
import hashlib
import json
from pathlib import Path
import sys


def bundle(source, destination):
    pin = json.loads((Path(__file__).resolve().parents[1] / "Integrations/Host/PIN.json").read_text())
    files = {}
    for name, expected in pin["files"].items():
        if Path(name).name != name:
            raise ValueError("Invalid host runtime filename")
        data = (source / name).read_bytes()
        if hashlib.sha256(data).hexdigest() != expected:
            raise ValueError("Host runtime differs from the reviewed source: " + name)
        files[name] = data
    destination.mkdir(parents=True, exist_ok=True)
    for name, data in files.items():
        (destination / name).write_bytes(data)
    (destination / "provenance.json").write_text(json.dumps(pin, indent=2) + "\n")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("Usage: bundle-host.py API_INTERNAL_DIRECTORY DESTINATION")
    bundle(Path(sys.argv[1]), Path(sys.argv[2]))
