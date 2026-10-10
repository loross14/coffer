#!/usr/bin/env python3
"""Local native-app adapter to pinned Grapheine discovery and review checks.

No keys, trust policy, Git repository or remote upload are created here. Local
proposals and verification are read-only; the native store performs separately
confirmed changes with checkpoint recovery. The optional legacy signed workflow
retains its externally provisioned policy and exact-write receipt requirements.
"""
from __future__ import annotations

import argparse
import base64
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
import unicodedata

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
        return {"status": "notConfigured", "message": "Local review is available. Choose the note to keep, then review and approve the exact changes. Matching names alone do not authorize pruning.", "questions": []}
    try:
        with policy_environment(policy, root):
            ctx = context(authority, policy, root)
            full_before = snapshot(root)
            before = control_pins(authority, ctx)
            report = authority.report(ctx)
            if snapshot(root) != full_before or control_pins(authority, ctx) != before:
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


# Discovery and local review cover Markdown. Legacy signed writes retain their
# separate full-folder inventory contract.
MAX_NOTE_BYTES = 8 * 1024 * 1024
MAX_DISCOVERY_BYTES = 256 * 1024 * 1024
MAX_DISCOVERY_NOTES = 20_000
MAX_SCOPE_ITEMS = 100
DISCOVERY_LIMITATIONS = [
    "Discovery covers included Markdown only. Its fingerprint does not verify whole-vault write eligibility or authorize pruning.",
    "Hidden directories, engine dependency directories, non-Markdown files, symbolic links and special entries are excluded. A listed folder represents its entire subtree.",
    "Obsidian userIgnoreFilters supports literal root-relative folder and file paths with exact spelling. Regex, glob, absolute, traversal and non-string filters are reported unsupported; full Obsidian filter semantics are not implemented.",
    "Graph links and canonical-owner paths resolve only to included notes. Absolute paths inside the original vault are mapped to included copies; external or excluded targets are omitted. Note bytes are not rewritten.",
    "Optional authority review and write preparation retain strict whole-vault checks, independently of discovery exclusions.",
]


def discovery_config(root):
    """Read only the specific exclusion configuration, never follow its links."""
    rootfd = os.open(str(root), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    configfd = None
    try:
        try:
            info = os.stat(".obsidian", dir_fd=rootfd, follow_symlinks=False)
        except FileNotFoundError:
            return {"identity": "absent", "applied": [], "unsupported": []}
        if not stat.S_ISDIR(info.st_mode):
            raise BridgeError("Obsidian exclusion settings are unavailable: .obsidian is not a regular directory.")
        configfd = os.open(".obsidian", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=rootfd)
        try:
            info = os.stat("app.json", dir_fd=configfd, follow_symlinks=False)
        except FileNotFoundError:
            return {"identity": "absent", "applied": [], "unsupported": []}
        if not stat.S_ISREG(info.st_mode) or info.st_size > 2 * 1024 * 1024:
            raise BridgeError("Obsidian app.json must be a regular configuration file no larger than 2 MiB.")
        descriptor = os.open("app.json", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=configfd)
        try:
            if stamp(info) != stamp(os.fstat(descriptor)):
                raise BridgeError("Obsidian exclusion settings changed during reading. Scan again.")
            chunks, total = [], 0
            while True:
                chunk = os.read(descriptor, 65536)
                if not chunk:
                    break
                total += len(chunk)
                if total > 2 * 1024 * 1024:
                    raise BridgeError("Obsidian app.json exceeds the 2 MiB configuration limit.")
                chunks.append(chunk)
            if stamp(info) != stamp(os.fstat(descriptor)):
                raise BridgeError("Obsidian exclusion settings changed during reading. Scan again.")
            raw = b"".join(chunks)
        finally:
            os.close(descriptor)
    finally:
        if configfd is not None:
            os.close(configfd)
        os.close(rootfd)
    try:
        document = json.loads(raw.decode("utf-8"))
        filters = document.get("userIgnoreFilters", [])
        if not isinstance(filters, list) or len(filters) > 4096:
            raise ValueError("userIgnoreFilters must be a list with at most 4,096 entries")
    except (UnicodeError, ValueError, AttributeError) as exc:
        raise BridgeError("Obsidian exclusion settings could not be read safely: " + str(exc)) from exc
    applied, unsupported = [], []
    for rule in filters:
        if (not isinstance(rule, str) or not rule or len(rule.encode("utf-8")) > 4096
                or rule.startswith("/") or any(c in rule for c in "\\*?[]{}|^$")
                or any(unicodedata.category(c) in ("Cc", "Cf") for c in rule)
                or any(part in ("", ".", "..") for part in (rule[:-1] if rule.endswith("/") else rule).split("/"))):
            label = rule if isinstance(rule, str) and rule else json.dumps(rule, ensure_ascii=False)
            unsupported.append(label[:4096])
        else:
            applied.append(rule)
    return {"identity": hashlib.sha256(raw).hexdigest(),
            "applied": sorted(set(applied)), "unsupported": sorted(set(unsupported))}


def discovery_inventory(root, graph, destination=None, *, strict=False):
    root = safe_path(root, directory=True)
    config = discovery_config(root)
    excluded, excluded_count, excluded_digest = [], 0, hashlib.sha256()
    files, stamps, directory_ids, canvas_paths = {}, {}, {}, []
    total_bytes, visited = 0, 0
    exact_rules = {rule.rstrip("/") for rule in config["applied"]}

    def exclude(path, reason, directory=False):
        nonlocal excluded_count
        label = path + "/" if directory else path
        excluded_count += 1
        excluded_digest.update(canonical([label, reason]) + b"\n")
        if len(excluded) < MAX_SCOPE_ITEMS:
            excluded.append(label)

    def visit(fd, prefix, depth):
        nonlocal total_bytes, visited
        if depth > 128:
            raise BridgeError("Discovery folder nesting exceeds the 128-level limit.")
        folder_info = os.fstat(fd)
        directory_ids[prefix] = (folder_info.st_dev, folder_info.st_ino)
        for name in sorted(os.listdir(fd)):
            name.encode("utf-8", errors="strict")
            relative = prefix + "/" + name if prefix else name
            visited += 1
            if visited > MAX_FILES:
                raise BridgeError("Discovery exceeds 250,000 visited entries. Add explicit folder exclusions and scan again.")
            try:
                info = os.stat(name, dir_fd=fd, follow_symlinks=False)
            except PermissionError:
                if strict:
                    raise BridgeError("Cannot verify the Markdown review scope: " + relative)
                exclude(relative, "unreadable entry")
                continue
            except FileNotFoundError as exc:
                raise BridgeError("Vault changed while scanning. Scan again.") from exc
            is_directory = stat.S_ISDIR(info.st_mode)
            if relative in exact_rules:
                exclude(relative, "Obsidian exclusion", is_directory)
                continue
            if is_directory and (name.startswith(".") or name in graph.SKIP_DIRS):
                exclude(relative, "hidden or engine directory", True)
                continue
            if not (is_directory or stat.S_ISREG(info.st_mode)):
                exclude(relative, "symbolic link or special entry")
                continue
            if is_directory:
                try:
                    child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                except PermissionError:
                    if strict:
                        raise BridgeError("Cannot verify the Markdown review scope: " + relative)
                    exclude(relative, "unreadable directory", True)
                    continue
                try:
                    if stamp(info) != stamp(os.fstat(child)):
                        raise BridgeError("Vault changed while scanning. Scan again.")
                    visit(child, relative, depth + 1)
                finally:
                    os.close(child)
            elif not name.endswith(".md"):
                if name.endswith(".canvas"):
                    canvas_paths.append(relative)
                exclude(relative, "non-Markdown file")
            else:
                if info.st_size > MAX_NOTE_BYTES:
                    raise BridgeError("Included Markdown exceeds the 8 MiB per-note discovery limit: " + relative)
                if len(files) >= MAX_DISCOVERY_NOTES or total_bytes + info.st_size > MAX_DISCOVERY_BYTES:
                    raise BridgeError("Discovery exceeds 20,000 notes or 256 MiB of included Markdown. Add explicit folder exclusions.")
                try:
                    child = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
                except PermissionError:
                    if strict:
                        raise BridgeError("Cannot verify the Markdown review scope: " + relative)
                    exclude(relative, "unreadable Markdown")
                    continue
                output = None
                try:
                    if stamp(info) != stamp(os.fstat(child)):
                        raise BridgeError("Vault changed while scanning. Scan again.")
                    if destination is not None:
                        target = destination / relative
                        target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                        output = os.open(str(target), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
                    hasher, count = hashlib.sha256(), 0
                    decoder = codecs.getincrementaldecoder("utf-8")("strict")
                    try:
                        while True:
                            chunk = os.read(child, 1024 * 1024)
                            if not chunk:
                                break
                            count += len(chunk)
                            if count > MAX_NOTE_BYTES or total_bytes + count > MAX_DISCOVERY_BYTES:
                                raise BridgeError("Included Markdown grew beyond discovery limits. Scan again.")
                            decoder.decode(chunk, final=False)
                            hasher.update(chunk)
                            if output is not None:
                                view = memoryview(chunk)
                                while view:
                                    written = os.write(output, view)
                                    if written <= 0:
                                        raise BridgeError("Could not prepare the private discovery copy.")
                                    view = view[written:]
                        decoder.decode(b"", final=True)
                    except UnicodeDecodeError as exc:
                        raise BridgeError("Included Markdown must use valid UTF-8: " + relative) from exc
                    if stamp(info) != stamp(os.fstat(child)) or count != info.st_size:
                        raise BridgeError("Vault changed while scanning. Scan again.")
                    files[relative], stamps[relative] = hasher.hexdigest(), stamp(info)
                    total_bytes += count
                finally:
                    if output is not None:
                        os.close(output)
                    os.close(child)

    descriptor = os.open(str(root), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        visit(descriptor, "", 0)
    finally:
        os.close(descriptor)
    limitations = list(DISCOVERY_LIMITATIONS)
    if len(config["applied"]) > MAX_SCOPE_ITEMS:
        limitations.append("All supported filters were applied; only the first 100 are listed.")
    if len(config["unsupported"]) > MAX_SCOPE_ITEMS:
        limitations.append("Only the first 100 unsupported filters are listed; none were applied.")
    scope = {"kind": "markdown-discovery", "excludedPaths": excluded,
             "excludedCount": excluded_count, "truncated": excluded_count > len(excluded),
             "appliedFilters": config["applied"][:MAX_SCOPE_ITEMS],
             "unsupportedFilters": config["unsupported"][:MAX_SCOPE_ITEMS], "limitations": limitations}
    return {"files": files, "stamps": stamps, "directories": directory_ids,
            "config": config, "scope": scope, "excludedIdentity": excluded_digest.hexdigest(),
            "canvasPaths": canvas_paths}


@contextlib.contextmanager
def scoped_graph(graph, root, stage, included):
    """Restrict filesystem-based engine reads/resolution to the admitted copies.

    The engine's graph algorithms and nomination rules are reused unchanged.
    Its path-based link resolution is narrowed to verified inventory membership.
    """
    from collections import defaultdict
    originals = {name: getattr(graph, name) for name in ("read_note", "collect_links", "_canonical_status")}
    admitted = {stage / relative for relative in included}
    links_cache = None

    def target(source, raw):
        candidate = Path(os.path.normpath(str(Path(raw) if Path(raw).is_absolute() else source.parent / raw)))
        for base in (stage, root):
            try:
                relative = candidate.relative_to(base).as_posix()
            except ValueError:
                continue
            if relative in included:
                return stage / relative
        return None

    def read_note(path):
        if Path(path) not in admitted:
            raise BridgeError("Engine attempted to read outside the verified discovery scope.")
        return originals["read_note"](path)

    def canonical_status(path, raw):
        found = target(path, str(raw))
        return ("resolved", str(found)) if found is not None else ("outside-discovery-scope", "")

    def collect_links(vaults):
        nonlocal links_cache
        if links_cache is not None:
            return links_cache
        if graph._as_list(vaults) != [stage]:
            raise BridgeError("Engine requested a different discovery root.")
        index = graph.vault_index([stage])
        forward, reverse, unresolved = defaultdict(list), defaultdict(set), defaultdict(set)
        files = sorted(admitted, key=str)
        for source in files:
            body, _ = read_note(source)
            body, seen = graph.strip_code(body), set()
            for match in graph.WIKILINK_RE.finditer(body):
                stem = match.group(1).strip().lower()
                if not stem or stem in seen:
                    continue
                seen.add(stem)
                candidates = index.get(stem)
                if candidates:
                    found = next((item for item in candidates if item.parent == source.parent), None) or candidates[0]
                    if found != source:
                        forward[source].append(found)
                        reverse[found].add(source)
                else:
                    unresolved[stem].add(source)
            for match in graph.MDLINK_RE.finditer(body):
                found = target(source, match.group(2).strip())
                if found is not None and found != source and found.stem.lower() not in seen:
                    seen.add(found.stem.lower())
                    forward[source].append(found)
                    reverse[found].add(source)
        links_cache = forward, reverse, unresolved, files, index
        return links_cache

    graph._index_cache.clear()
    graph._links_cache.clear()
    graph.read_note, graph.collect_links, graph._canonical_status = read_note, collect_links, canonical_status
    try:
        yield
    finally:
        for name, function in originals.items():
            setattr(graph, name, function)
        graph._index_cache.clear()
        graph._links_cache.clear()


def discovery_fingerprint(inventory):
    return digest({"files": inventory["files"], "config": inventory["config"],
                   "scope": inventory["scope"], "excludedIdentity": inventory["excludedIdentity"],
                   "canvasPaths": inventory["canvasPaths"]})


def scan(graph, authority, root, policy=None):
    import tempfile
    root = safe_path(root, directory=True)
    with tempfile.TemporaryDirectory(prefix=".planisphere-discovery-") as temporary:
        stage = Path(temporary).resolve()
        before = discovery_inventory(root, graph, destination=stage)
        with scoped_graph(graph, root, stage, before["files"]):
            accounts = graph._accounts_payload([stage], top=MAX_GROUPS, include_generic=False)
            diagnostics = [accounts["claims_boundary"]]
            try:
                doctor = graph._obstruction_payload([stage], 5, 300)
                diagnostics.extend(graph._doctor_actions(doctor))
            except Exception as exc:
                diagnostics.append("Graph diagnostics unavailable: " + str(exc))
        auth = authority_scan(authority, policy, root)
        if discovery_inventory(root, graph) != before:
            raise BridgeError("Vault or discovery scope changed while scanning. No current scan was published; scan again.")
    groups = []
    for group in accounts["candidate_groups"]:
        members = group["members"]
        if len(members) > 1000:
            diagnostics.append("Candidate group " + group["candidate_key"] + " is truncated to 1,000 members.")
        groups.append({"id": digest(group), "candidateKey": group["candidate_key"],
                       "members": members[:1000], "declaredCopies": group["declared_copies"]})
    if accounts["candidate_group_count"] > MAX_GROUPS:
        diagnostics.append("Showing the first 200 candidate groups; additional groups exist.")
    diagnostics.append("Discovery freshness covers included Markdown and exclusions, not attachment contents or whole-vault write readiness.")
    if before["config"]["unsupported"]:
        diagnostics.append("Some Obsidian exclusion filters are unsupported and were not applied; review the listed scope limitations.")
    return {"engineVersion": graph.__version__, "scannedAt": datetime.now(timezone.utc).isoformat(),
            "vaultPath": str(root), "notes": accounts["notes"],
            "totalGroups": accounts["candidate_group_count"], "groups": groups,
            "diagnostics": diagnostics, "authority": auth, "scope": before["scope"],
            "fingerprint": discovery_fingerprint(before)}


LOCAL_SCHEMA = "planisphere-local-prune-v1"
LOCAL_LIMITATIONS = [
    "You choose the note to keep and approve these exact changes. This local review is not an externally signed authority decision.",
    "Only included Markdown is reviewed and changed. Links from excluded folders, other vaults, attachments, or external applications are not checked or updated.",
    "Grapheine checks supported links, citations, and holds. It does not prove that the kept note preserves every meaning; read the retired notes before approving.",
    "Planisphere saves Markdown checkpoints before and after applying. Close other editors and sync during application; interrupted operations retain recovery information.",
]


def local_helper(filename):
    # Load our companion from the app's own resource directory, never a vault.
    guard_path = Path(__file__).resolve().with_name(filename)
    namespace = {"__name__": "planisphere_" + filename.removesuffix(".py")}
    exec(compile(read_regular(guard_path), str(guard_path), "exec"), namespace)
    return namespace


def prepare_local(graph, authority, root, members, keep, fingerprint):
    """Read-only local proposal. The native store owns recovery and all writes.

    This deliberately does not manufacture a signed decision, permission, Git
    HEAD, or success record for the independently governed settlement protocol.
    """
    import tempfile
    root = safe_path(root, directory=True)
    if (not isinstance(members, list) or not 2 <= len(members) <= 1000
            or not all(isinstance(n, str) for n in members)
            or len(set(members)) != len(members) or keep not in members):
        raise BridgeError("Choose one complete candidate group and explicitly select its note to keep.")
    if not isinstance(fingerprint, str) or not re.fullmatch(r"[0-9a-f]{64}", fingerprint):
        raise BridgeError("Scan this vault before preparing local changes.")
    with tempfile.TemporaryDirectory(prefix=".planisphere-local-review-") as temporary:
        stage = Path(temporary).resolve()
        before = discovery_inventory(root, graph, destination=stage, strict=True)
        if discovery_fingerprint(before) != fingerprint:
            raise BridgeError("The vault or review scope changed since scanning. Scan again.")
        if not set(members).issubset(before["files"]):
            raise BridgeError("Every candidate must be a current included Markdown note.")
        if before["canvasPaths"]:
            raise BridgeError("Canvas links need preservation review before pruning: " + before["canvasPaths"][0])
        texts = {name: (stage / name).read_bytes().decode("utf-8") for name in before["files"]}
        retired_aliases = []
        for name in set(members) - {keep}:
            _, metadata = graph.read_note(stage / name)
            retired_aliases.extend(graph.fm_list(metadata, "alias") + graph.fm_list(metadata, "aliases"))
        guard = local_helper("local_guard.py")
        guard["validate_local_markdown"](texts, root, members=members, retired=set(members)-{keep}, retired_aliases=retired_aliases)
        attachment_references = guard["local_attachment_references"]
        kept_attachments = attachment_references(texts[keep], keep)
        for retired in set(members) - {keep}:
            if attachment_references(texts[retired], retired) - kept_attachments:
                raise BridgeError("Unique attachment references would leave the active note: " + retired)
        with scoped_graph(graph, root, stage, before["files"]):
            accounts = graph._accounts_payload([stage], top=MAX_GROUPS, include_generic=False)
            if not any(set(g["members"]) == set(members) for g in accounts["candidate_groups"]):
                raise BridgeError("The selected members are not one complete current candidate group. Scan again.")
            changes = local_helper("local_plan.py")["make_local_changes"](graph, authority, stage, members, keep, set(before["files"]))
            preserve_code_examples(authority, {"packet": {"changes": changes}}, stage)
        if not changes or set(name for name, after in changes.items() if after is None) != set(members) - {keep}:
            raise BridgeError("The proposed retirements do not match the reviewed choice.")
        if discovery_inventory(root, graph, strict=True) != before:
            raise BridgeError("Vault or exclusions changed during preparation. Scan and review again.")
        payload = {"schema": LOCAL_SCHEMA, "engineCommit": ENGINE_COMMIT,
                   "vault": str(root), "value": keep, "members": sorted(members),
                   "files": before["files"], "fingerprint": fingerprint,
                   "scope": {"version": 2, "excludedPaths": before["config"]["applied"],
                             "sourceConfigurationSHA256": None if before["config"]["identity"] == "absent" else before["config"]["identity"]},
                   "changes": changes,
                   "originals": {name: base64.b64encode((stage / name).read_bytes()).decode("ascii") for name in changes},
                   "limitations": LOCAL_LIMITATIONS}
    packet = {"packet": payload, "digest": digest(payload)}
    if len(canonical(packet)) > MAX_JSON_BYTES:
        raise BridgeError("Prepared changes exceed the supported 32 MiB review limit.")
    return packet


def verify_local(graph, authority, root, packet_path):
    packet_path = safe_path(packet_path)
    if authority.inside(packet_path, root):
        raise BridgeError("The reviewed packet must be outside the working vault.")
    packet = json.loads(read_regular(packet_path))
    payload = packet.get("packet", {})
    if payload.get("schema") != LOCAL_SCHEMA or payload.get("vault") != str(root):
        raise BridgeError("The reviewed changes belong to another vault or unsupported review format.")
    fresh = prepare_local(graph, authority, root, payload.get("members"), payload.get("value"), payload.get("fingerprint"))
    if fresh != packet:
        raise BridgeError("The reviewed changes were modified or are stale. Prepare a new review.")
    return fresh


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


def graph_snapshot(graph, root):
    import tempfile
    helper_path = Path(__file__).resolve().with_name("graph_adapter.py")
    namespace = {"__name__": "planisphere_graph_adapter"}
    exec(compile(read_regular(helper_path), str(helper_path), "exec"), namespace)
    with tempfile.TemporaryDirectory(prefix=".planisphere-graph-") as temporary:
        stage = Path(temporary).resolve()
        before = discovery_inventory(root, graph, destination=stage)
        texts = {name: (stage / name).read_bytes().decode("utf-8") for name in before["files"]}
        result = namespace["build_graph"](texts, str(root))
        if discovery_inventory(root, graph) != before:
            raise BridgeError("Vault or exclusions changed while loading the graph. Refresh the graph.")
    return {**result, "vaultPath": str(root), "scannedAt": datetime.now(timezone.utc).isoformat(),
            "scope": before["scope"]}


def main(argv=None):
    class JSONArgumentParser(argparse.ArgumentParser):
        def error(self, message):
            raise BridgeError(message)
    parser = JSONArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["scan", "graph", "prepare", "apply", "prepare-local", "verify-local"])
    parser.add_argument("--engine-root", required=True)
    parser.add_argument("--vault", required=True)
    parser.add_argument("--policy")
    parser.add_argument("--scope")
    parser.add_argument("--question")
    parser.add_argument("--packet")
    parser.add_argument("--receipt")
    parser.add_argument("--members")
    parser.add_argument("--keep")
    parser.add_argument("--fingerprint")
    try:
        args = parser.parse_args(argv)
        root = safe_path(args.vault, directory=True)
        # Engine output is not the native transport. Return only our JSON object.
        with contextlib.redirect_stdout(io.StringIO()):
            graph, authority = load_engine(args.engine_root)
            if args.action == "scan":
                result = scan(graph, authority, root, args.policy)
            elif args.action == "graph":
                if args.policy:
                    raise BridgeError("Graph discovery does not use an authority policy.")
                result = graph_snapshot(graph, root)
            elif args.action in ("prepare-local", "verify-local"):
                if args.policy:
                    raise BridgeError("A configured signed policy cannot be bypassed by a local review request.")
                if args.action == "prepare-local":
                    if not args.members or not args.keep or not args.fingerprint:
                        raise BridgeError("Local preparation requires the complete group, chosen note, and current scan.")
                    result = prepare_local(graph, authority, root, json.loads(args.members), args.keep, args.fingerprint)
                else:
                    if not args.packet:
                        raise BridgeError("Verification requires the exact reviewed packet.")
                    result = verify_local(graph, authority, root, args.packet)
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
