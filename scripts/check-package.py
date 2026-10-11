#!/usr/bin/env python3
"""Exercise the packaged engine with no developer tools or user Python setup."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile


def pdf_fixture():
    text = b"BT /F1 18 Tf 40 150 Td (packagedpdfneedle) Tj ET"
    objects = [b"<< /Type /Catalog /Pages 2 0 R >>",
               b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
               b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
               b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
               b"<< /Length " + str(len(text)).encode() + b" >>\nstream\n" + text + b"\nendstream"]
    data = bytearray(b"%PDF-1.4\n")
    offsets = [0]
    for index, value in enumerate(objects, 1):
        offsets.append(len(data))
        data += str(index).encode() + b" 0 obj\n" + value + b"\nendobj\n"
    xref = len(data)
    data += b"xref\n0 6\n0000000000 65535 f \n"
    for offset in offsets[1:]:
        data += ("%010d 00000 n \n" % offset).encode()
    data += ("trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % xref).encode()
    return bytes(data)


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
        (vault / "Status.md").write_text("# Current\nSee [[Archive/Status]]. [Code](model.py) [Paper](Paper.pdf) [Source](Main.tex)\n", encoding="utf-8")
        (vault / "Archive/Status.md").write_text("# Earlier\n", encoding="utf-8")
        (vault / "model.py").write_text("# Read, never execute\nvalue = 'packagedcodeneedle'\n", encoding="utf-8")
        (vault / "Main.tex").write_text("\\section{Main}\\label{main}\n", encoding="utf-8")
        (vault / "Paper.pdf").write_bytes(pdf_fixture())
        original = {str(path.relative_to(vault)): hashlib.sha256(path.read_bytes()).hexdigest()
                    for path in vault.rglob("*") if path.is_file()}
        env = {"HOME": str(home), "PATH": "/no-developer-tools", "TMPDIR": temporary,
               "PYTHONHOME": "/invalid-host-runtime", "PYTHONPATH": "/invalid-host-modules",
               "PLANISPHERE_READER_CACHE": str(root / "reader-cache")}
        def run(arguments):
            result = subprocess.run([str(python), "-B", "-s", "-E", "-X", "utf8", *arguments],
                                    env=env, cwd=temporary, capture_output=True, text=True, timeout=60)
            if result.returncode:
                raise RuntimeError(result.stdout + result.stderr)
            return json.loads(result.stdout)
        runtime = run(["-c", "import sys,json,ssl,sqlite3,ctypes,lzma; from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey; k=Ed25519PrivateKey.from_private_bytes(bytes(range(32))); k.public_key().verify(k.sign(b'fixture'),b'fixture'); print(json.dumps({'prefix':sys.prefix,'version':sys.version.split()[0]}))"])
        if not Path(runtime["prefix"]).resolve().is_relative_to(contents):
            raise RuntimeError("Python loaded a runtime outside the app.")
        scan = run([str(helper), "scan", "--engine-root", str(engine), "--vault", str(vault)])
        graph = run([str(helper), "graph", "--engine-root", str(engine), "--vault", str(vault)])
        if scan.get("notes") != 2 or len(scan.get("groups", [])) != 1:
            raise RuntimeError("Packaged discovery did not find the fixture notes and duplicate group.")
        if len(graph.get("nodes", [])) != 2 or len(graph.get("edges", [])) != 1:
            raise RuntimeError("Packaged graph did not return the fixture relationship.")
        def invoke(action, *arguments):
            return run([str(helper), action, "--engine-root", str(engine), "--vault", str(vault), *arguments])
        documents = invoke("graph-documents")
        if len(documents.get("nodes", [])) != 5 or len(documents.get("edges", [])) != 4:
            raise RuntimeError("Packaged document graph did not preserve explicit links.")
        for query, path, location in [("packagedcodeneedle", "model.py", {"line": 2}),
                                       ("packagedpdfneedle", "Paper.pdf", {"page": 1})]:
            search = invoke("search-documents", "--query", query)
            matches = search.get("matches", [])
            if len(matches) != 1 or matches[0]["path"] != path or matches[0]["location"] != location:
                raise RuntimeError("Packaged search returned the wrong original passage.")
            key, value = next(iter(location.items()))
            read = invoke("read-document", "--path", path, "--" + key, str(value))
            if query not in read.get("body", ""):
                raise RuntimeError("Packaged reader did not open the selected search passage.")
        after = {str(path.relative_to(vault)): hashlib.sha256(path.read_bytes()).hexdigest()
                 for path in vault.rglob("*") if path.is_file()}
        if after != original or (vault / ".git").exists():
            raise RuntimeError("Packaged read operations changed the fixture vault.")
        print(json.dumps({"signature": "valid", "runtime": runtime["version"],
                          "externalPython": False, "notes": scan["notes"],
                          "edges": len(graph["edges"]), "documents": len(documents["nodes"]),
                          "pdfAndCodeSearch": "passed", "vaultUnchanged": True}))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: check-package.py Planisphere.app")
    check(Path(sys.argv[1]))
