#!/usr/bin/env python3
"""Package the checksum-pinned, relocatable Apple Silicon Python runtime."""
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import sys
import tarfile
import tempfile

VERSION = "3.13.16"
RELEASE = "20261009"
ARCHIVE = "cpython-3.13.16+20261009-aarch64-apple-darwin-install_only_stripped.tar.gz"
URL = "https://github.com/astral-sh/python-build-standalone/releases/download/" + RELEASE + "/" + ARCHIVE
SHA256 = "11785155d0f70e634178219c20925d8f20be00a3da4684fc4f5019dd15602ef7"


def bundle(archive, framework):
    if hashlib.sha256(archive.read_bytes()).hexdigest() != SHA256:
        raise SystemExit("Python archive checksum mismatch; no runtime was bundled.")
    if framework.exists():
        raise SystemExit("Refusing to replace an existing Python framework.")
    framework.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=framework.parent) as temporary:
        # Only the exact pinned upstream archive reaches extraction.
        with tarfile.open(archive) as source:
            source.extractall(temporary)
        version = framework / "Versions" / "3.13"
        version.parent.mkdir(parents=True)
        shutil.move(str(Path(temporary) / "python"), version)

    # Use the conventional framework executable layout, preserving Python's
    # relative stdlib lookup and all upstream license notices.
    executable = version / "bin" / "python3.13"
    executable.rename(version / "Python")
    executable.symlink_to("../Python")
    (version.parent / "Current").symlink_to("3.13")
    (framework / "Python").symlink_to("Versions/Current/Python")
    (framework / "Resources").symlink_to("Versions/Current/Resources")
    resources = version / "Resources"
    resources.mkdir()
    with (resources / "Info.plist").open("wb") as output:
        plistlib.dump({
            "CFBundleIdentifier": "ooo.planisphere.python",
            "CFBundleName": "Python",
            "CFBundleExecutable": "Python",
            "CFBundlePackageType": "FMWK",
            "CFBundleVersion": VERSION,
            "CFBundleShortVersionString": VERSION,
            "LSMinimumSystemVersion": "14.0",
        }, output)
    (resources / "provenance.json").write_text(json.dumps({
        "source": URL, "sha256": SHA256, "version": VERSION,
        "architecture": "arm64", "release": RELEASE,
        "license": "../lib/python3.13/LICENSE.txt",
    }, indent=2) + "\n")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("Usage: bundle-python.py ARCHIVE Python.framework\nDownload: " + URL)
    bundle(Path(sys.argv[1]), Path(sys.argv[2]))
