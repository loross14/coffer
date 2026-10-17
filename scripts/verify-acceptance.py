#!/usr/bin/env python3
"""Read-only checks for the explicitly supplied Planisphere UI acceptance fixture.

Usage: python3 scripts/verify-acceptance.py FIXTURE_ROOT --original-vault-id UUID
Exit 0: all checks passed; 1: mismatch; 2: baseline UUID omitted (incomplete).
The UUID must have been recorded before remove/re-add. This checks the resulting
files and identities; the operator separately records the UI actions and restart.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
import uuid


ORIGINAL_RESEARCH = (
    b"# Research\n\nDecision: ship local vault management first.\n\n"
    b"Managed storage develops in parallel and stays optional.\n"
)
LATEST_RESEARCH = (
    b"# Research\n\nDecision: local vault management ships first.\n\n"
    b"Managed storage is optional and develops in parallel.\n"
)
ORIGINAL = {
    ".obsidian": None,
    ".obsidian/app.json": b'{"alwaysUpdateLinks": true}\n',
    "Archive": None,
    "Attachments": None,
    "Attachments/sample.bin": bytes([0, 255, 2, 128, 10]) * 100,
    "Research.md": ORIGINAL_RESEARCH,
    "Welcome.md": (
        b"# Field Notes\n\nA local vault for the Planisphere acceptance run.\n\n"
        b"- Keep the original files.\n- Save a checkpoint before making changes.\n"
        b"- Recover earlier work as a separate copy.\n"
    ),
}
LATEST = dict(ORIGINAL, **{
    "Research.md": LATEST_RESEARCH,
    "Added.md": b"# Added\n\nSecond checkpoint.\n",
})
WORKING = dict(LATEST, **{
    "Research.md": LATEST_RESEARCH + b"\nUnsaved edit stays only in the working vault.\n",
})
DIGEST = re.compile(r"[0-9a-f]{64}\Z")
DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW


def require(condition, message):
    if not condition:
        raise ValueError(message)


def identifier(value):
    require(isinstance(value, str), "missing UUID")
    return str(uuid.UUID(value)).upper()


def parts(relative):
    require(isinstance(relative, str) and relative, "empty relative path")
    result = relative.split("/")
    require(all(p not in ("", ".", "..") for p in result)
            and "\\" not in relative and "\0" not in relative,
            "unsafe relative path")
    return result


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate JSON key: " + key)
        result[key] = value
    return result


class Fixture:
    """All reads are relative to one directory descriptor; never follow links."""

    def __init__(self, root):
        self.root = Path(root).resolve(strict=True)
        self.fd = os.open(self.root, DIRECTORY_FLAGS)

    def directory(self, relative):
        fd = os.dup(self.fd)
        try:
            for component in parts(relative):
                child = os.open(component, DIRECTORY_FLAGS, dir_fd=fd)
                os.close(fd)
                fd = child
            return fd
        except Exception:
            os.close(fd)
            raise

    @staticmethod
    def read_at(fd, name):
        child = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
        try:
            info = os.fstat(child)
            require(stat.S_ISREG(info.st_mode), "not a regular file: " + name)
            require(info.st_size <= 64 * 1024 * 1024, "fixture file exceeds 64 MiB")
            with os.fdopen(child, "rb", closefd=False) as stream:
                data = stream.read(64 * 1024 * 1024 + 1)
            require(len(data) == info.st_size, "file changed during verification: " + name)
            return data
        finally:
            os.close(child)

    def read(self, relative):
        components = parts(relative)
        fd = self.directory("/".join(components[:-1])) if len(components) > 1 else os.dup(self.fd)
        try:
            return self.read_at(fd, components[-1])
        finally:
            os.close(fd)

    def tree(self, relative):
        result = {}

        def walk(fd, prefix):
            for name in sorted(os.listdir(fd)):
                parts(name)
                path = prefix + name
                info = os.stat(name, dir_fd=fd, follow_symlinks=False)
                if stat.S_ISDIR(info.st_mode):
                    result[path] = None
                    child = os.open(name, DIRECTORY_FLAGS, dir_fd=fd)
                    try:
                        walk(child, path + "/")
                    finally:
                        os.close(child)
                else:
                    require(stat.S_ISREG(info.st_mode), "link or special file: " + path)
                    result[path] = self.read_at(fd, name)

        fd = self.directory(relative)
        try:
            walk(fd, "")
            return result
        finally:
            os.close(fd)

    def envelope(self, relative):
        data = json.loads(self.read(relative), object_pairs_hook=unique_object)
        require(isinstance(data, dict) and isinstance(data.get("payload"), dict),
                "invalid metadata envelope: " + relative)
        require(isinstance(data.get("sha256"), str) and DIGEST.fullmatch(data["sha256"]),
                "invalid metadata checksum field: " + relative)
        require(data["payload"].get("formatVersion") == 1, "unsupported metadata format")
        return data["payload"]


def compare_tree(actual, expected):
    require(set(actual) == set(expected),
            "tree paths differ; missing=" + repr(sorted(set(expected) - set(actual)))
            + "; extra=" + repr(sorted(set(actual) - set(expected))))
    for path, data in expected.items():
        require(actual[path] == data, "bytes or entry kind differ: " + path)


def check_manifest(manifest, expected, objects):
    require(isinstance(manifest.get("entries"), list), "missing manifest entries")
    entries = {}
    for entry in manifest["entries"]:
        path = entry["path"]
        parts(path)
        require(path not in entries, "duplicate manifest path: " + path)
        entries[path] = entry
    require(set(entries) == set(expected), "manifest paths differ from expected fixture")
    for path, data in expected.items():
        entry = entries[path]
        require(entry.get("executable") is False, "unexpected executable bit: " + path)
        if data is None:
            require(entry.get("kind") == "directory" and entry.get("digest") is None
                    and entry.get("size") == 0, "invalid directory entry: " + path)
        else:
            digest = hashlib.sha256(data).hexdigest()
            require(entry.get("kind") == "file" and entry.get("digest") == digest
                    and entry.get("size") == len(data), "invalid file entry: " + path)
            require(objects.get(digest) == data, "missing or different object: " + path)


def export_history(fixture):
    prefix = "Field Notes Export/history"
    info = fixture.envelope(prefix + "/export.json")
    vault_id = identifier(info["vault"]["id"])
    current_id = identifier(info["currentCheckpointID"])
    files = fixture.tree(prefix + "/checkpoints")
    require(len(files) == 2 and all(p.endswith(".json") and "/" not in p for p in files),
            "export must contain exactly two checkpoint manifests")
    manifests = {}
    for filename in files:
        manifest = fixture.envelope(prefix + "/checkpoints/" + filename)
        checkpoint_id = identifier(manifest["id"])
        require(identifier(filename[:-5]) == checkpoint_id, "manifest filename/ID mismatch")
        require(identifier(manifest["vaultID"]) == vault_id, "manifest vault ID mismatch")
        require(checkpoint_id not in manifests, "duplicate checkpoint identity")
        manifests[checkpoint_id] = manifest
    require(current_id in manifests, "export current checkpoint is missing")
    current = manifests[current_id]
    older_id = identifier(current.get("parentID"))
    require(older_id != current_id and older_id in manifests, "invalid checkpoint parent")
    older = manifests[older_id]
    require(older.get("parentID") is None, "original checkpoint must have no parent")
    objects = fixture.tree(prefix + "/objects")
    for digest, data in objects.items():
        require(DIGEST.fullmatch(digest) is not None and isinstance(data, bytes),
                "invalid object filename or kind")
        require(hashlib.sha256(data).hexdigest() == digest, "corrupt object: " + digest)
    check_manifest(older, ORIGINAL, objects)
    check_manifest(current, LATEST, objects)
    referenced = {e["digest"] for m in manifests.values() for e in m["entries"] if e["kind"] == "file"}
    require(set(objects) == referenced, "export object set differs from referenced objects")
    return {"vault_id": vault_id, "current_id": current_id, "older_id": older_id,
            "manifests": manifests, "object_count": len(objects)}


def registry_identity(fixture, exported, original_id):
    require(exported is not None, "export history must pass before identity checks")
    registry = fixture.envelope("history/registry.json")
    records = registry["vaults"]
    source_path = str(fixture.root / "Field Notes")
    matches = [record for record in records if record.get("path") == source_path]
    require(len(matches) == 1, "source must have exactly one canonical registry record")
    record = matches[0]
    vault_id = identifier(record["id"])
    require(vault_id == exported["vault_id"], "registry identity differs from pre-removal export")
    require(record.get("archived") is False, "original vault is still removed")
    require(record.get("name") == "Field Notes", "original vault name changed")
    if original_id:
        require(vault_id == original_id, "original registration identity changed")
    prefix = "history/vaults/" + vault_id
    head = fixture.envelope(prefix + "/head.json")
    require(identifier(head["checkpointID"]) == exported["current_id"], "local history head changed")
    local_files = fixture.tree(prefix + "/checkpoints")
    require(set(local_files) == {key + ".json" for key in exported["manifests"]},
            "original checkpoint identities changed")
    for checkpoint_id, manifest in exported["manifests"].items():
        require(fixture.envelope(prefix + "/checkpoints/" + checkpoint_id + ".json") == manifest,
                "local and exported checkpoint payloads differ")
        for entry in manifest["entries"]:
            if entry["kind"] == "file":
                data = fixture.read("history/objects/" + entry["digest"])
                require(len(data) == entry["size"] and hashlib.sha256(data).hexdigest() == entry["digest"],
                        "local history object differs: " + entry["path"])
    return {"vault_id": vault_id, "checkpoint_count": len(local_files)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("fixture_root", help="only this supplied fixture directory will be inspected")
    parser.add_argument("--original-vault-id", type=identifier,
                        help="UUID recorded before remove/re-add; required for complete acceptance")
    args = parser.parse_args()
    checks = []

    def check(name, action):
        try:
            result = action()
            checks.append({"name": name, "status": "passed"})
            return result
        except (OSError, ValueError, KeyError, TypeError, AttributeError) as error:
            checks.append({"name": name, "status": "failed", "detail": str(error)})
            return None

    fixture = check("fixture_root", lambda: Fixture(args.fixture_root))
    exported = None
    identity = None
    if fixture:
        try:
            check("recovered_original_bytes_and_empty_directory", lambda: compare_tree(
                fixture.tree("Field Notes Recovered"), ORIGINAL))
            check("export_latest_saved_bytes_and_empty_directory", lambda: compare_tree(
                fixture.tree("Field Notes Export/files"), LATEST))
            check("working_vault_unsaved_edit_only", lambda: compare_tree(
                fixture.tree("Field Notes"), WORKING))
            exported = check("export_two_checkpoint_chain_and_all_objects", lambda: export_history(fixture))
            identity = check("registry_identity_and_local_history", lambda: registry_identity(
                fixture, exported, args.original_vault_id))
        finally:
            os.close(fixture.fd)
    checks.append({"name": "original_registration_uuid",
                   "status": "passed" if args.original_vault_id and identity else "not_checked",
                   "detail": "baseline comparison depends on registry check" if args.original_vault_id
                   else "supply --original-vault-id recorded before remove/re-add"})
    checks.append({"name": "metadata_payload_checksums", "status": "not_checked",
                   "detail": "Swift canonical JSON is not reproduced; object hashes/sizes have separate checks"})
    failed = sum(c["status"] == "failed" for c in checks)
    complete = bool(args.original_vault_id) and not failed
    report = {"ok": not failed, "complete": complete, "checks": checks}
    if exported:
        report["history"] = {key: exported[key] for key in ("vault_id", "current_id", "older_id", "object_count")}
    print(json.dumps(report, indent=2, sort_keys=True))
    return 1 if failed else (0 if complete else 2)


if __name__ == "__main__":
    sys.exit(main())
