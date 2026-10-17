#!/usr/bin/env python3
"""Sign nested executables from the inside out, then seal the app."""
from pathlib import Path
import subprocess
import sys

MACHO = {b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
         b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"}


def sign(app, identity):
    # Ad-hoc identities have no Team ID, so hardened runtime library validation
    # rejects their bundled extension modules. Distribution identities retain
    # hardened runtime; local ad-hoc packages clear that option explicitly.
    args = ["/usr/bin/codesign", "--force", "--sign", identity, "--options", "0" if identity == "-" else "runtime",
            "--preserve-metadata=identifier,entitlements", "--generate-entitlement-der",
            "--timestamp=none" if identity == "-" else "--timestamp"]
    files = sorted(app.rglob("*"), key=lambda path: len(path.parts), reverse=True)
    code_files = []
    for path in files:
        if path.is_symlink() or not path.is_file():
            continue
        with path.open("rb") as source:
            is_code = source.read(4) in MACHO
        if is_code:
            code_files.append(path)
            subprocess.run([*args, str(path)], check=True)
    for path in files:
        if path.is_dir() and not path.is_symlink() and path.suffix in {".framework", ".app", ".xpc", ".bundle"}:
            # SwiftPM resource-only bundles have no executable/Info.plist.
            # Their bytes are sealed by the containing app resource signature.
            if path.suffix == ".bundle" and not any(path in item.parents for item in code_files):
                continue
            subprocess.run([*args, str(path)], check=True)
    subprocess.run([*args, str(app)], check=True)
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("Usage: sign-bundle.py APP SIGNING_IDENTITY")
    sign(Path(sys.argv[1]), sys.argv[2])
