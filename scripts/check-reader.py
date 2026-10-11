#!/usr/bin/env python3
"""Check the vendored Planisphere reader against its recorded source fingerprint."""
import hashlib
import json
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
reader = root / "Integrations/Grapheine/planisphere_reader.py"
manifest = json.loads(reader.with_name("reader-provenance.json").read_text())
digest = hashlib.sha256(reader.read_bytes()).hexdigest()
if digest != manifest["sha256"]:
    raise SystemExit("The bundled reader differs from its recorded API source. Review and update both copies.")
if len(sys.argv) > 1 and Path(sys.argv[1]).read_bytes() != reader.read_bytes():
    raise SystemExit("The Mac and API reader sources differ.")
print("Planisphere reader source fingerprint verified.")
