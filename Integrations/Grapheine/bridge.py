#!/usr/bin/env python3
"""Local native-app adapter to the pinned Grapheine authority workflow.

No keys, trust policy, Git repository or remote upload are created here. Scan is
read-only. Preparation/application retain the engine's G1–G5 checks and require
an externally provisioned policy and externally signed exact-write receipt.
"""
from __future__ import annotations

import argparse
import contextlib
import codecs
from datetime import datetime, timezone
import hashlib
import io
import json
import os
from pathlib import Path
import re
import stat
import sys
import types

sys.dont_write_bytecode = True
ENGINE_COMMIT = "c013207c1fb1140fd20819fb61e1b7a25980ea88"
ENGINE_HASHES = {
    "grapheine.py": "5d14831ad9ae36532ed482daccd35d3847b38287f8e6c55c90891d6ff4560584",
    "grapheine_authority.py": "cc531bd2abc8c9a8e3174ed180aeb1269497d118366bb7985c51d6c866b097a4",
}
MAX_JSON_BYTES = 32 * 1024 * 1024
MAX_FILES = 250_000
MAX_GROUPS = 200


class BridgeError(ValueError):
    pass


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False).encode("utf-8")


def digest(value):
    return hashlib.sha256(canonical(value)).hexdigest()


def safe_path(raw, *, directory=False, may_be_missing=False):
    path = Path(raw)
    if not path.is_absolute() or ".." in path.parts or "\0" in str(path):
        raise BridgeError("Use an absolute path without traversal components.")
    for candidate in [*reversed(path.parents), path]:
        try:
            info = candidate.lstat()
        except FileNotFoundError:
            if candidate == path and may_be_missing:
                return path
            raise BridgeError("Path is unavailable: " + str(candidate))
        if stat.S_ISLNK(info.st_mode):
            raise BridgeError("Symbolic links are not supported: " + str(candidate))
        if candidate != path and not stat.S_ISDIR(info.st_mode):
            raise BridgeError("Path ancestor is not a directory: " + str(candidate))
    expected = stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode)
    if not expected:
        raise BridgeError("Expected a regular file or directory: " + str(path))
    return path.resolve()


def read_regular(path, maximum=MAX_JSON_BYTES):
    path = safe_path(path)
    descriptor = os.open(str(path), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_size > maximum:
            raise BridgeError("Input file is unsupported or exceeds the size limit: " + str(path))
        chunks, size = [], 0
        while True:
            chunk = os.read(descriptor, min(1024 * 1024, maximum + 1 - size))
            if not chunk:
                break
            chunks.append(chunk)
            size += len(chunk)
            if size > maximum:
                raise BridgeError("Input grew beyond the supported size limit.")
        if stamp(before) != stamp(os.fstat(descriptor)):
            raise BridgeError("Input changed while it was read.")
        return b"".join(chunks)
    finally:
        os.close(descriptor)


def stamp(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def snapshot(root):
    """Full regular-file inventory, including hidden config and attachments.

    Git internals are excluded to match the engine's G3 inventory. A .git entry
    is still checked for unsafe file type before excluding its contents.
    """
    root = safe_path(root, directory=True)
    files, stamps = {}, {}
    def visit(fd, prefix):
        before = os.fstat(fd)
        stamps[prefix] = stamp(before)
        for name in sorted(os.listdir(fd)):
            name.encode("utf-8", errors="strict")
            relative = prefix + "/" + name if prefix else name
            info = os.stat(name, dir_fd=fd, follow_symlinks=False)
            if not (stat.S_ISREG(info.st_mode) or stat.S_ISDIR(info.st_mode)):
                raise BridgeError("Symbolic links and special files are unsupported: " + relative)
            if name == ".git":
                continue
            if len(stamps) >= MAX_FILES:
                raise BridgeError("Vault exceeds the 250,000-entry scan limit.")
            if stat.S_ISDIR(info.st_mode):
                child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                try:
                    if stamp(info) != stamp(os.fstat(child)):
                        raise BridgeError("Vault changed while scanning. Scan again.")
                    visit(child, relative)
                finally:
                    os.close(child)
            else:
                child = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
                try:
                    if stamp(info) != stamp(os.fstat(child)):
                        raise BridgeError("Vault changed while scanning. Scan again.")
                    hasher = hashlib.sha256()
                    decoder = codecs.getincrementaldecoder("utf-8")("strict") if name.endswith(".md") else None
                    try:
                        while True:
                            chunk = os.read(child, 1024 * 1024)
                            if not chunk:
                                break
                            hasher.update(chunk)
                            if decoder:
                                decoder.decode(chunk, final=False)
                        if decoder:
                            decoder.decode(b"", final=True)
                    except UnicodeDecodeError as exc:
                        raise BridgeError("Markdown must use valid UTF-8 before scanning or pruning: " + relative) from exc
                    if stamp(info) != stamp(os.fstat(child)):
                        raise BridgeError("Vault changed while scanning. Scan again.")
                    files[relative] = hasher.hexdigest()
                    stamps[relative] = stamp(info)
                finally:
                    os.close(child)
        if stamp(before) != stamp(os.fstat(fd)):
            raise BridgeError("Vault changed while scanning. Scan again.")
    descriptor = os.open(str(root), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        visit(descriptor, "")
    finally:
        os.close(descriptor)
    return {"files": files, "stamps": stamps}


def load_engine(engine_root):
    directory = safe_path(engine_root, directory=True)
    loaded, sources = {}, {}
    # Check the complete pair before executing either module.
    for filename, expected in ENGINE_HASHES.items():
        source = read_regular(directory / filename, maximum=8 * 1024 * 1024)
        if hashlib.sha256(source).hexdigest() != expected:
            raise BridgeError("Unsupported Grapheine source. Use the bundled engine pinned to " + ENGINE_COMMIT + ".")
        sources[filename] = source
    # Compile verified bytes directly: an existing .pyc cannot replace checked source.
    # Grapheine imports authority constants at module load, so load that module first.
    for filename in ("grapheine_authority.py", "grapheine.py"):
        source = sources[filename]
        name = filename[:-3]
        module = types.ModuleType(name)
        module.__file__ = str(directory / filename)
        sys.modules[name] = module
        exec(compile(source, module.__file__, "exec"), module.__dict__)
        loaded[name] = module
    graph, authority = loaded["grapheine"], loaded["grapheine_authority"]
    original_git = authority.git
    def read_safe_git(root, *args, env=None, input_text=None):
        return original_git(root, *args, env={"GIT_OPTIONAL_LOCKS": "0", **(env or {})}, input_text=input_text)
    authority.git = read_safe_git
    return graph, authority


@contextlib.contextmanager
def policy_environment(policy, root):
    keys = ["GRAPHITE_AUTHORITY_POLICY", "GRAPHITE_VAULT_ROOTS", "GIT_OPTIONAL_LOCKS"]
    old = {key: os.environ.get(key) for key in keys}
    os.environ["GRAPHITE_AUTHORITY_POLICY"] = str(policy)
    os.environ["GRAPHITE_VAULT_ROOTS"] = str(root)
    # Read-only Git checks must not opportunistically refresh the user's index.
    os.environ["GIT_OPTIONAL_LOCKS"] = "0"
    try:
        yield
    finally:
        for key, value in old.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value


def context(authority, policy, root):
    policy = safe_path(policy)
    # Validate control paths before the engine reads or resolves them.
    raw = json.loads(read_regular(policy))
    safe_path(raw["manifest"])
    safe_path(raw["store"], may_be_missing=True)
    ctx = authority.policy_context()
    if ctx["path"] != policy or ctx["root"] != root:
        raise BridgeError("The authority policy belongs to a different vault.")
    return ctx


def control_pins(authority, ctx):
    return {name: authority.file_hash(ctx[name]) if ctx[name].exists() else None
            for name in ("path", "manifest", "store")}


def authority_scan(authority, policy, root):
    if not policy:
        return {"status": "notConfigured", "message": "No authority policy selected. Candidate matches do not authorize pruning.", "questions": []}
    try:
        with policy_environment(policy, root):
            ctx = context(authority, policy, root)
            before = control_pins(authority, ctx)
            report = authority.report(ctx)
            if control_pins(authority, ctx) != before:
                raise BridgeError("Authority inputs changed during review. Scan again.")
            questions = []
            for item in report["resolved_graph"] + report["residual_graph"]:
                questions.append({
                    "scope": item["scope"], "question": item["question"],
                    "values": item["values"], "state": item["state"],
                    "value": item.get("value"), "proofs": item.get("proofs", []),
                    "writeState": item.get("write_state"), "hold": item.get("hold"),
                })
            message = "Declared decisions are verified separately from permission for exact file changes."
            if report.get("rejected_records"):
                message += " Some authority records were rejected; inspect the configured authority log."
            if len(questions) > MAX_GROUPS:
                message += " Showing the first 200 declared questions."
            return {"status": "available", "message": message, "questions": questions[:MAX_GROUPS]}
    except Exception as exc:
        return {"status": "unavailable", "message": str(exc), "questions": []}


def scan(graph, authority, root, policy=None):
    before = snapshot(root)
    graph._index_cache.clear()
    graph._links_cache.clear()
    accounts = graph._accounts_payload([root], top=MAX_GROUPS, include_generic=False)
    diagnostics = [accounts["claims_boundary"]]
    try:
        doctor = graph._obstruction_payload([root], 5, 300)
        diagnostics.extend(graph._doctor_actions(doctor))
    except Exception as exc:
        diagnostics.append("Graph diagnostics unavailable: " + str(exc))
    auth = authority_scan(authority, policy, root)
    if snapshot(root) != before:
        raise BridgeError("Vault changed while scanning. No current scan was published; scan again.")
    groups = []
    for group in accounts["candidate_groups"]:
        members = group["members"]
        if len(members) > 1000:
            diagnostics.append("Candidate group " + group["candidate_key"] + " is truncated to 1,000 members.")
        groups.append({"id": digest(group), "candidateKey": group["candidate_key"],
                       "members": members[:1000], "declaredCopies": group["declared_copies"]})
    if accounts["candidate_group_count"] > MAX_GROUPS:
        diagnostics.append("Showing the first 200 candidate groups; additional groups exist.")
    diagnostics.append("Graph diagnostics cover Markdown outside hidden/generated folders. Freshness also checks hidden configuration and attachments. Matches and structural signals are not permission to delete or merge notes.")
    return {"engineVersion": graph.__version__, "scannedAt": datetime.now(timezone.utc).isoformat(),
            "vaultPath": str(root), "notes": accounts["notes"],
            "totalGroups": accounts["candidate_group_count"], "groups": groups,
            "diagnostics": diagnostics, "authority": auth,
            "fingerprint": digest(before["files"])}


# Keep code examples byte-exact. The current engine's settlement parser can
# recognize link-like text inside code; this adapter holds those proposed edits.
CODE = re.compile(r"(?ms)(^[ \t]{0,3}(`{3,}|~{3,})[^\n]*\n.*?(?:^[ \t]{0,3}\2[^\n]*(?:\n|$)|\Z))|(`+)([^`]*?)\3")
ESCAPED_LINK = re.compile(r"\\\[(?:\[[^\n]*?\]\]|[^\]\n]*\]\([^\n)]*\))")
INDENTED_CODE = re.compile(r"(?m)^(?: {4}|\t).*(?:\n|$)")


def code_literals(text):
    return ([match.group(0) for match in CODE.finditer(text)]
            + ESCAPED_LINK.findall(text) + INDENTED_CODE.findall(text))


def preserve_code_examples(authority, packet, root):
    for name, content in packet["packet"]["changes"].items():
        if content is None:
            continue
        original = read_regular(authority.note_path(root, name)).decode("utf-8")
        if code_literals(original) != code_literals(content):
            raise BridgeError("Code examples would change; review in the editor first: " + name)


def prepare(authority, root, policy, scope, question):
    before = snapshot(root)
    with policy_environment(policy, root):
        ctx = context(authority, policy, root)
        packet = authority.build_packet(ctx, scope, question)
        preserve_code_examples(authority, packet, root)
    if snapshot(root) != before:
        raise BridgeError("Vault changed during preparation. Prepare a new packet.")
    if len(canonical(packet)) > MAX_JSON_BYTES:
        raise BridgeError("Prepared packet exceeds the supported 32 MiB limit.")
    return packet


def apply(authority, root, policy, packet_path, receipt_path):
    snapshot(root)  # Refuse special files before the engine's whole-file reads.
    packet_path, receipt_path = safe_path(packet_path), safe_path(receipt_path)
    if authority.inside(packet_path, root) or authority.inside(receipt_path, root):
        raise BridgeError("Packet and signed permission must be outside the working vault.")
    read_regular(packet_path)
    read_regular(receipt_path)
    with policy_environment(policy, root):
        ctx = context(authority, policy, root)
        packet, receipt = authority.load(packet_path), authority.load(receipt_path)
        if packet.get("packet", {}).get("vault") != str(root):
            raise BridgeError("The packet belongs to a different vault.")
        fresh = authority.build_packet(ctx, packet["packet"]["scope"], packet["packet"]["question"])
        if fresh != packet:
            raise BridgeError("G3: stale or modified settlement packet. Prepare a new packet.")
        preserve_code_examples(authority, fresh, root)
        authority.verify_permission(receipt, fresh, ctx)
        try:
            result = authority.apply_packet(packet, receipt, ctx)
        except authority.Refusal as exc:
            completed = re.fullmatch(r"commit ([0-9a-f]{40,64}) succeeded, but index refresh failed; inspect the Git index", str(exc))
            if not completed or authority.git(root, "rev-parse", "HEAD") != completed.group(1):
                raise
            return {"commit": completed.group(1), "packet_digest": packet["digest"],
                    "files_changed": len(packet["packet"]["changes"]),
                    "message": "Settlement committed, but the Git index could not be refreshed. The completed commit was verified at HEAD. Inspect the index before further work; do not apply this packet again."}
    return {**result, "message": "All existing Grapheine gates passed; signed settlement committed."}


def main(argv=None):
    class JSONArgumentParser(argparse.ArgumentParser):
        def error(self, message):
            raise BridgeError(message)
    parser = JSONArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["scan", "prepare", "apply"])
    parser.add_argument("--engine-root", required=True)
    parser.add_argument("--vault", required=True)
    parser.add_argument("--policy")
    parser.add_argument("--scope")
    parser.add_argument("--question")
    parser.add_argument("--packet")
    parser.add_argument("--receipt")
    try:
        args = parser.parse_args(argv)
        root = safe_path(args.vault, directory=True)
        # Engine output is not the native transport. Return only our JSON object.
        with contextlib.redirect_stdout(io.StringIO()):
            graph, authority = load_engine(args.engine_root)
            if args.action == "scan":
                result = scan(graph, authority, root, args.policy)
            else:
                if not args.policy:
                    raise BridgeError("Select an externally provisioned authority policy first.")
                if args.action == "prepare":
                    if not args.scope or not args.question:
                        raise BridgeError("Preparation requires a declared scope and question.")
                    result = prepare(authority, root, args.policy, args.scope, args.question)
                else:
                    if not args.packet or not args.receipt:
                        raise BridgeError("Application requires the exact packet and its separately signed permission.")
                    result = apply(authority, root, args.policy, args.packet, args.receipt)
        encoded = json.dumps(result, ensure_ascii=False, sort_keys=True, allow_nan=False)
        if len(encoded.encode("utf-8")) > MAX_JSON_BYTES:
            raise BridgeError("Bridge result exceeds the supported 32 MiB limit.")
        print(encoded)
        return 0
    except Exception as exc:
        payload = {"error": str(exc)}
        print(json.dumps(payload, ensure_ascii=False))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
