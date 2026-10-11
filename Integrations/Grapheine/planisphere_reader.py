#!/usr/bin/env python3
"""Planisphere's scoped local document reader (Python 3.9+, stdlib plus macOS PDFKit).

Search accepts SQLite FTS5 syntax, including quoted terms, AND/OR, parentheses,
and token prefixes. Obsidian regex queries are not supported. The disposable
index is private and outside the vault; originals remain the read authority.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import sqlite3
import stat
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

SCHEMA = "planisphere-reader-v1"
DB_VERSION = "3"
DEFAULT_CACHE = Path.home() / ".local/state/planisphere/native-reader"
MAX_NOTES = 20_000
MAX_TOTAL_BYTES = 256 * 1024 * 1024
MAX_FILE_BYTES = 8 * 1024 * 1024
MAX_ENTRIES = 250_000
MAX_DEPTH = 128
MAX_CONFIG_BYTES = 1024 * 1024
MAX_QUERY_BYTES = 4096
MAX_FILTERS = 256
DEPENDENCY_DIRS = frozenset({"node_modules", "__pycache__", "venv", "site-packages"})
DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
FILE_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
FORMAT_EXTENSIONS = {
    "markdown": {".md"}, "tex": {".tex", ".bib"}, "pdf": {".pdf"},
    "text": {".txt", ".rst"}, "html": {".html", ".htm", ".css"},
    "code": {".py", ".pyi", ".swift", ".js", ".jsx", ".ts", ".tsx", ".mjs", ".cjs",
             ".c", ".h", ".cc", ".cpp", ".hpp", ".rs", ".go", ".java", ".kt", ".rb",
             ".sh", ".bash", ".zsh", ".sql", ".r", ".R", ".scala", ".cs", ".lua"},
}
PDF_SCRIPT = r'''
ObjC.import('Foundation'); ObjC.import('PDFKit');
const data = $.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile;
const doc = $.PDFDocument.alloc.initWithData(data);
function extract() {
    if (!doc || doc.isNil()) return {error: 'invalid_pdf'};
    if (doc.isLocked) return {error: 'locked_pdf'};
    if (doc.pageCount > 500) return {error: 'pdf_limit'};
    let pages = [], size = 0;
    for (let i = 0; i < doc.pageCount; i++) {
        const value = doc.pageAtIndex(i).string;
        const text = value && !value.isNil() ? ObjC.unwrap(value) : '';
        size += text.length;
        if (size > 2000000) return {error: 'pdf_limit'};
        pages.push(text.replace(/\f/g, '\n'));
    }
    return {pages: pages};
}
JSON.stringify(extract());
'''


def document_format(path):
    suffix = Path(path).suffix
    if suffix.casefold() == ".md":
        return "markdown" if suffix == ".md" else None
    return next((kind for kind, extensions in FORMAT_EXTENSIONS.items() if suffix.casefold() in {value.casefold() for value in extensions}), None)


def extract_pdf(data, timeout):
    """Extract from the already verified bytes; PDFKit never receives a vault path."""
    if sys.platform != "darwin":
        raise ReaderError("pdf_unavailable", "PDF text reading currently requires macOS PDFKit.")
    if not data.startswith(b"%PDF-"):
        raise ReaderError("invalid_pdf", "The source is not a supported PDF document.")
    try:
        result = subprocess.run(["/usr/bin/osascript", "-l", "JavaScript", "-e", PDF_SCRIPT],
                                input=data, capture_output=True, check=False, timeout=max(0.01, min(timeout, 15)),
                                env={"PATH": "/usr/bin:/bin", "HOME": str(Path.home())})
    except subprocess.TimeoutExpired:
        raise ReaderError("timeout", "PDF text extraction exceeded its time budget.") from None
    try:
        payload = json.loads(result.stdout)
    except (ValueError, UnicodeError):
        raise ReaderError("pdf_extraction_failed", "PDFKit could not extract this document.") from None
    error = payload.get("error")
    messages = {"invalid_pdf": "The PDF could not be opened.", "locked_pdf": "The PDF is password locked.",
                "pdf_limit": "The PDF exceeds 500 pages or the extracted text limit."}
    if error or result.returncode:
        raise ReaderError(error or "pdf_extraction_failed", messages.get(error, "PDF text extraction failed."))
    pages = payload.get("pages")
    if (not isinstance(pages, list) or not 1 <= len(pages) <= 500 or
            not all(isinstance(page, str) for page in pages)):
        raise ReaderError("pdf_extraction_failed", "PDFKit returned an invalid page map.")
    body = "\f".join(pages)
    if len(body.encode("utf-8")) > MAX_FILE_BYTES:
        raise ReaderError("limit_exceeded", "Extracted PDF text exceeds the reader size limit.")
    return body


class ReaderError(Exception):
    """An intentionally bounded, content-free error suitable for JSON output."""

    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


def _stamp(info):
    return (info.st_dev, info.st_ino, info.st_ctime_ns, info.st_mtime_ns, info.st_size)


def _identity(info):
    return (info.st_dev, info.st_ino)


def _digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _json(value) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def _search_passage(body, marked, markers, kind):
    """Locate the actual FTS excerpt, not a different occurrence of a query term."""
    start, end, omitted = markers
    leading, trailing = marked.startswith(omitted), marked.endswith(omitted)
    fragment = marked[len(omitted):] if leading else marked
    fragment = fragment[:-len(omitted)] if trailing else fragment
    anchor = fragment.find(start)
    location = {}
    if anchor >= 0:
        offset = body.find(fragment.replace(start, "").replace(end, ""))
        if offset < 0:
            raise ReaderError("invalid_cache", "The search excerpt could not be located in its indexed source.")
        prefix = body[:offset + anchor]
        line = len(prefix.splitlines()) + int(not prefix or prefix[-1] in "\n\r\v\f\x1c\x1d\x1e\x85\u2028\u2029")
        location = {"page": prefix.count("\f") + 1} if kind == "pdf" else {"line": line}
    display = fragment.replace(start, "[").replace(end, "]")
    # Long tokens/whitespace must not push the matching term out of the preview.
    left = max(0, anchor - 80) if len(display) > 318 and anchor >= 0 else 0
    right = left + 318
    snippet = ("…" if leading or left else "") + display[left:right] + ("…" if trailing or len(display) > right else "")
    return snippet, location


def _absolute_directory(path: Path, create=False, forbidden_identity=None):
    """Open each component without following links; caller owns the result fd."""
    if not path.is_absolute() or ".." in path.parts:
        raise ReaderError("invalid_root", "An absolute directory without parent traversal is required.")
    fd = os.open("/", DIRECTORY_FLAGS)
    try:
        if _identity(os.fstat(fd)) == forbidden_identity:
            raise ReaderError("invalid_cache", "The search cache must be outside the selected vault.")
        for part in path.parts[1:]:
            if create:
                try:
                    os.mkdir(part, mode=0o700, dir_fd=fd)
                except FileExistsError:
                    pass
            next_fd = os.open(part, DIRECTORY_FLAGS, dir_fd=fd)
            if _identity(os.fstat(next_fd)) == forbidden_identity:
                os.close(next_fd)
                raise ReaderError("invalid_cache", "The search cache must be outside the selected vault.")
            os.close(fd)
            fd = next_fd
        return fd
    except BaseException:
        os.close(fd)
        raise


class Reader:
    def __init__(self, vault: str, vault_root, *, cache_root=None, timeout=8.0, excluded_paths=(), formats=("markdown",)):
        if not formats or any(kind not in FORMAT_EXTENSIONS for kind in formats):
            raise ReaderError("invalid_formats", "Select supported document formats explicitly.")
        self.formats = tuple(sorted(set(formats)))
        if not isinstance(excluded_paths, (list, tuple)) or len(excluded_paths) > MAX_FILTERS:
            raise ReaderError("invalid_scope", "Reader exclusions must be a bounded list of relative paths.")
        self.excluded_paths = tuple(excluded_paths)
        for path in self.excluded_paths:
            if (not isinstance(path, str) or not path or path.startswith("/") or "\\" in path
                    or any(ord(c) < 32 for c in path) or
                    any(part in {"", ".", ".."} for part in path.rstrip("/").split("/"))):
                raise ReaderError("invalid_scope", "Reader exclusions must be literal relative paths.")
        if not isinstance(vault, str) or not vault.strip() or len(vault) > 180 or any(ord(c) < 32 for c in vault):
            raise ReaderError("invalid_vault", "A nonempty vault label of at most 180 characters is required.")
        if not math.isfinite(timeout) or not 0 < timeout <= 60:
            raise ReaderError("invalid_timeout", "Timeout must be greater than zero and at most 60 seconds.")
        self.deadline = time.monotonic() + timeout
        self.vault = vault
        requested = Path(vault_root)
        if not requested.is_absolute() or ".." in requested.parts:
            raise ReaderError("invalid_root", "An explicit absolute vault root is required.")
        # Validate the supplied spelling as well as the canonical identity. This
        # rejects a symlink anywhere in the root path, not only its final name.
        try:
            self.root_fd = _absolute_directory(requested)
        except OSError:
            raise ReaderError("invalid_root", "Vault root is missing, inaccessible, or contains a symbolic link.") from None
        try:
            self.root = requested.resolve(strict=True)
        except OSError:
            os.close(self.root_fd)
            raise ReaderError("invalid_root", "The selected vault root changed while it was being opened.") from None
        self.root_identity = _identity(os.fstat(self.root_fd))
        self.cache_root = Path(cache_root) if cache_root is not None else DEFAULT_CACHE
        self.filters = []
        self.scope_stamp = None

    def close(self):
        if self.root_fd is not None:
            os.close(self.root_fd)
            self.root_fd = None

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()

    def _check_time(self):
        if time.monotonic() >= self.deadline:
            raise ReaderError("timeout", "The local reader time budget was exhausted.")

    def _check_root(self):
        self._check_time()
        try:
            fd = _absolute_directory(self.root)
            try:
                valid = _identity(os.fstat(fd)) == self.root_identity
            finally:
                os.close(fd)
        except OSError:
            valid = False
        if not valid:
            raise ReaderError("source_changed", "The selected vault root changed during the operation.")

    def _parts(self, path: str, *, config=False):
        if not isinstance(path, str) or not path or len(path.encode("utf-8")) > 4096:
            raise ReaderError("invalid_path", "A bounded relative document path is required.")
        parts = path.split("/")
        if path.startswith("/") or "\\" in path or "\x00" in path or any(p in ("", ".", "..") for p in parts):
            raise ReaderError("invalid_path", "Paths must be relative and may not traverse parent directories.")
        if len(parts) > MAX_DEPTH + 1:
            raise ReaderError("limit_exceeded", "The maximum directory depth was exceeded.")
        if not config:
            if document_format(path) not in self.formats:
                raise ReaderError("invalid_path", "The file type is outside the selected reading formats.")
            if self._excluded(path) or any(p.startswith(".") for p in parts) or any(p.casefold() in DEPENDENCY_DIRS for p in parts[:-1]):
                raise ReaderError("excluded_path", "The requested path is excluded from this vault's read scope.")
        return parts

    def _parent(self, parts):
        fd = os.dup(self.root_fd)
        try:
            for part in parts[:-1]:
                self._check_time()
                next_fd = os.open(part, DIRECTORY_FLAGS, dir_fd=fd)
                os.close(fd)
                fd = next_fd
            return fd
        except BaseException:
            os.close(fd)
            raise

    def _read_bytes(self, path, *, expected=None, config=False, raw=False):
        self._check_time()
        parts = self._parts(path, config=config)
        maximum = MAX_CONFIG_BYTES if config else MAX_FILE_BYTES
        parent = self._parent(parts)
        try:
            fd = os.open(parts[-1], FILE_FLAGS, dir_fd=parent)
            try:
                before = os.fstat(fd)
                if not stat.S_ISREG(before.st_mode):
                    raise ReaderError("unsafe_file", "Only regular files can be read; symbolic links and special files are excluded.")
                if before.st_size > maximum:
                    raise ReaderError("limit_exceeded", "A file exceeds the local reader size limit.")
                if expected is not None and _stamp(before) != tuple(expected):
                    raise ReaderError("source_changed", "A source changed during the operation; retry with a fresh inventory.")
                chunks = []
                length = 0
                while True:
                    self._check_time()
                    block = os.read(fd, min(65536, maximum + 1 - length))
                    if not block:
                        break
                    chunks.append(block)
                    length += len(block)
                    if length > maximum:
                        raise ReaderError("limit_exceeded", "A file exceeds the local reader size limit.")
                after = os.fstat(fd)
                named = os.stat(parts[-1], dir_fd=parent, follow_symlinks=False)
                if _stamp(before) != _stamp(after) or _stamp(after) != _stamp(named) or length != after.st_size:
                    raise ReaderError("source_changed", "A source changed while its original bytes were being read.")
                # A parent directory can be renamed while its fd remains open.
                # Reopen the path from the pinned root to verify the name still
                # designates the same parent and the same final file.
                current_parent = self._parent(parts)
                try:
                    current = os.stat(parts[-1], dir_fd=current_parent, follow_symlinks=False)
                    if _identity(os.fstat(parent)) != _identity(os.fstat(current_parent)) or _stamp(current) != _stamp(after):
                        raise ReaderError("source_changed", "A source path was replaced during the operation.")
                finally:
                    os.close(current_parent)
                data = b"".join(chunks)
                if raw:
                    return data, None, _stamp(after)
                if not config and document_format(path) == "pdf":
                    body = extract_pdf(data, self.deadline - time.monotonic())
                    self._check_time()
                    # Extraction can outlive an editor write; check the original again.
                    verified, _, _ = self._read_bytes(path, expected=_stamp(after), raw=True)
                    if verified != data:
                        raise ReaderError("source_changed", "The PDF changed during extraction.")
                    return data, body, _stamp(after)
                if b"\x00" in data:
                    raise ReaderError("invalid_text", "A source contains NUL bytes and cannot be treated as text.")
                try:
                    body = data.decode("utf-8")
                except UnicodeDecodeError:
                    raise ReaderError("invalid_text", "A source is not valid UTF-8 text.") from None
                self._check_time()
                return data, body, _stamp(after)
            finally:
                os.close(fd)
        finally:
            os.close(parent)

    def _scope(self):
        try:
            data, body, stamp = self._read_bytes(".planisphere/scope.json", config=True)
        except FileNotFoundError:
            return [], None
        try:
            config = json.loads(body)
        except (ValueError, TypeError):
            raise ReaderError("invalid_scope", "The Planisphere scope configuration is not valid JSON.") from None
        if not isinstance(config, dict):
            raise ReaderError("invalid_scope", "The Planisphere scope configuration must be an object.")
        rules = config.get("pathPrefixes", [])
        if not isinstance(rules, list) or len(rules) > MAX_FILTERS:
            raise ReaderError("unsupported_scope", "Scope exclusions must be a bounded list of literal path prefixes.")
        filters = []
        for rule in rules:
            if not isinstance(rule, str) or not rule or rule.startswith("/") or "\\" in rule or "\x00" in rule or ".." in rule.split("/"):
                raise ReaderError("unsupported_scope", "Only nonempty literal relative path-prefix exclusions are supported; regex exclusions require explicit support.")
            filters.append(rule.casefold())
        paths = config.get("excludedPaths", [])
        if not isinstance(paths, list) or len(paths) > MAX_FILTERS or any(
                not isinstance(path, str) or not path or path.startswith("/") or "\\" in path or
                any(ord(char) < 32 for char in path) or
                any(part in {"", ".", ".."} for part in path.rstrip("/").split("/")) for path in paths):
            raise ReaderError("unsupported_scope", "Excluded paths must be bounded literal relative paths.")
        return sorted(set(filters)), (stamp, _digest(data), tuple(paths))

    def _load_scope(self):
        self.filters, self.scope_stamp = self._scope()

    def _check_scope(self):
        if self._scope() != (self.filters, self.scope_stamp):
            raise ReaderError("source_changed", "Vault exclusion settings changed during the operation.")

    def _excluded(self, path):
        value = path.casefold()
        return (any(value.startswith(prefix) for prefix in self.filters) or
                any(value == prefix.rstrip("/").casefold() or
                    value.startswith(prefix.rstrip("/").casefold() + "/")
                    for prefix in (*self.excluded_paths, *(self.scope_stamp[2] if self.scope_stamp else ()))))

    def _inventory(self):
        notes = {}
        total = 0
        counts = {"entries": 0, "hidden": 0, "dependencies": 0, "configured": 0, "symlinks": 0, "special": 0}

        def visit(fd, prefix, depth):
            nonlocal total
            self._check_time()
            if depth > MAX_DEPTH:
                raise ReaderError("limit_exceeded", "The maximum directory depth was exceeded.")
            entries = []
            with os.scandir(fd) as iterator:
                for entry in iterator:
                    self._check_time()
                    counts["entries"] += 1
                    if counts["entries"] > MAX_ENTRIES:
                        raise ReaderError("limit_exceeded", "The maximum inventory entry count was exceeded.")
                    entries.append(entry.name)
            for name in sorted(entries):
                self._check_time()
                path = prefix + name
                if name.startswith("."):
                    counts["hidden"] += 1
                    continue
                if self._excluded(path):
                    counts["configured"] += 1
                    continue
                info = os.stat(name, dir_fd=fd, follow_symlinks=False)
                if stat.S_ISLNK(info.st_mode):
                    counts["symlinks"] += 1
                    continue
                if stat.S_ISDIR(info.st_mode):
                    if name.casefold() in DEPENDENCY_DIRS:
                        counts["dependencies"] += 1
                        continue
                    child = os.open(name, DIRECTORY_FLAGS, dir_fd=fd)
                    try:
                        if _identity(os.fstat(child)) != _identity(info):
                            raise ReaderError("source_changed", "A directory changed during inventory.")
                        visit(child, path + "/", depth + 1)
                        if _identity(os.stat(name, dir_fd=fd, follow_symlinks=False)) != _identity(info):
                            raise ReaderError("source_changed", "A directory was replaced during inventory.")
                    finally:
                        os.close(child)
                    continue
                if not stat.S_ISREG(info.st_mode):
                    counts["special"] += 1
                    continue
                if document_format(name) not in self.formats:
                    continue
                self._parts(path)
                if info.st_size > MAX_FILE_BYTES:
                    raise ReaderError("limit_exceeded", "A source file exceeds the local reader size limit.")
                notes[path] = _stamp(info)
                total += info.st_size
                if len(notes) > MAX_NOTES or total > MAX_TOTAL_BYTES:
                    raise ReaderError("limit_exceeded", "The vault exceeds the local reader inventory limits.")

        visit(self.root_fd, "", 0)
        return notes, total, counts

    def _connect(self):
        cache = self.cache_root
        if not cache.is_absolute() or ".." in cache.parts:
            raise ReaderError("invalid_cache", "The cache root must be an absolute path outside the vault.")
        if cache == self.root or self.root in cache.parents:
            raise ReaderError("invalid_cache", "The search cache must be outside the selected vault.")
        # Lexical ancestry is insufficient on case-insensitive APFS and for
        # filesystem aliases. Refuse the actual vault inode before creating
        # any descendant in the cache path.
        parent = _absolute_directory(cache, create=True, forbidden_identity=self.root_identity)
        identity = str(self.root) if self.formats == ("markdown",) else _json([str(self.root), self.formats, "documents-v1"])
        folder = _digest(identity.encode("utf-8"))
        try:
            try:
                os.mkdir(folder, mode=0o700, dir_fd=parent)
            except FileExistsError:
                pass
            private = os.open(folder, DIRECTORY_FLAGS, dir_fd=parent)
        finally:
            os.close(parent)
        try:
            info = os.fstat(private)
            if info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) & 0o077:
                raise ReaderError("unsafe_cache", "The per-vault search cache directory must be private to its owner.")
            fd = os.open("index.sqlite3", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600, dir_fd=private)
            try:
                info = os.fstat(fd)
                if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) & 0o077:
                    raise ReaderError("unsafe_cache", "The search index must be a private regular file.")
            finally:
                os.close(fd)
        finally:
            os.close(private)
        self._check_time()
        conn = sqlite3.connect(str(cache / folder / "index.sqlite3"), timeout=min(1.0, max(0.001, self.deadline - time.monotonic())), isolation_level=None)
        conn.row_factory = sqlite3.Row
        conn.set_progress_handler(lambda: int(time.monotonic() >= self.deadline), 1000)
        return conn

    def _schema(self, conn):
        conn.execute("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        metadata = dict(conn.execute("SELECT key,value FROM meta"))
        if metadata and (metadata.get("schema") != DB_VERSION or metadata.get("root") != str(self.root)):
            raise ReaderError("invalid_cache", "The existing index has an incompatible schema or vault identity.")
        conn.execute("CREATE TABLE IF NOT EXISTS notes (id INTEGER PRIMARY KEY, path TEXT UNIQUE NOT NULL, dev INTEGER NOT NULL, ino INTEGER NOT NULL, ctime_ns INTEGER NOT NULL, mtime_ns INTEGER NOT NULL, size INTEGER NOT NULL, sha256 TEXT NOT NULL)")
        try:
            conn.execute("CREATE VIRTUAL TABLE IF NOT EXISTS search USING fts5(path, body, tokenize='unicode61')")
        except sqlite3.OperationalError:
            self._check_time()
            raise ReaderError("index_unavailable", "SQLite FTS5 is required for native search.") from None
        conn.execute("INSERT OR IGNORE INTO meta(key,value) VALUES('schema',?)", (DB_VERSION,))
        conn.execute("INSERT OR IGNORE INTO meta(key,value) VALUES('root',?)", (str(self.root),))

    def _refresh(self, conn, inventory):
        existing = {row["path"]: row for row in conn.execute("SELECT * FROM notes")}
        reads = 0
        for path in sorted(set(existing) - set(inventory)):
            self._check_time()
            conn.execute("DELETE FROM search WHERE rowid=?", (existing[path]["id"],))
            conn.execute("DELETE FROM notes WHERE path=?", (path,))
        for path, stamp in sorted(inventory.items()):
            self._check_time()
            old = existing.get(path)
            if old is not None and tuple(old[key] for key in ("dev", "ino", "ctime_ns", "mtime_ns", "size")) == stamp:
                continue
            data, body, _ = self._read_bytes(path, expected=stamp)
            sha = _digest(data)
            if old is not None:
                row_id = old["id"]
                conn.execute("DELETE FROM search WHERE rowid=?", (row_id,))
                conn.execute("UPDATE notes SET dev=?,ino=?,ctime_ns=?,mtime_ns=?,size=?,sha256=? WHERE id=?", (*stamp, sha, row_id))
            else:
                row_id = conn.execute("INSERT INTO notes(path,dev,ino,ctime_ns,mtime_ns,size,sha256) VALUES(?,?,?,?,?,?,?)", (path, *stamp, sha)).lastrowid
            conn.execute("INSERT INTO search(rowid,path,body) VALUES(?,?,?)", (row_id, path, body))
            reads += 1
        return reads

    def _snapshot(self, inventory, total, counts, reads, live_reads):
        digest = hashlib.sha256()
        for path, stamp in sorted(inventory.items()):
            self._check_time()
            digest.update(_json([path, stamp]).encode("utf-8"))
            digest.update(b"\n")
        digest.update(_json(self.scope_stamp).encode("utf-8"))
        digest.update(_json(self.excluded_paths).encode("utf-8"))
        checked_at = datetime.now(timezone.utc).isoformat()  # noqa: UP017 - standalone Python 3.9 support
        return {
            "indexed_notes": len(inventory), "indexed_bytes": total,
            "refresh_reads": reads, "selected_live_reads": live_reads,
            "freshness": {"checked_at": checked_at, "inventory_sha256": digest.hexdigest(), "basis": "stat inventory checked before and after; returned hits verified against live original bytes"},
            "scope": {"formats": list(self.formats), "hidden_paths": "excluded", "dependency_directories": sorted(DEPENDENCY_DIRS), "literal_path_prefixes": self.filters, "excluded_paths": list(self.excluded_paths) + list(self.scope_stamp[2] if self.scope_stamp else ()), "symbolic_links": "excluded", "special_files": "excluded", "inventory_counts": counts},
            "limits": {"notes": MAX_NOTES, "total_bytes": MAX_TOTAL_BYTES, "file_bytes": MAX_FILE_BYTES, "entries": MAX_ENTRIES, "depth": MAX_DEPTH},
        }

    def _indexed(self, query=None, limit=20):
        self._load_scope()
        inventory, total, counts = self._inventory()
        conn = self._connect()
        try:
            conn.execute("BEGIN IMMEDIATE")
            self._schema(conn)
            reads = self._refresh(conn, inventory)
            matches = []
            if query is not None:
                marker = "PLANISPHERE" + uuid.uuid4().hex
                markers = (marker + "START", marker + "END", marker + "OMITTED")
                try:
                    rows = conn.execute("SELECT n.*, search.body AS body, snippet(search,1,?,?,?,32) AS snippet FROM search JOIN notes n ON n.id=search.rowid WHERE search MATCH ? ORDER BY bm25(search,5,1), n.path LIMIT ?", (*markers, query, limit))
                except sqlite3.OperationalError as error:
                    self._check_time()
                    message = str(error).lower()
                    if any(token in message for token in ("fts5: syntax", "unterminated string", "no such column", "malformed match")):
                        raise ReaderError("invalid_query", "The query is not valid SQLite FTS5 syntax.") from None
                    raise
                for row in rows:
                    stamp = tuple(row[key] for key in ("dev", "ino", "ctime_ns", "mtime_ns", "size"))
                    data, _, _ = self._read_bytes(row["path"], expected=stamp, raw=True)
                    sha = _digest(data)
                    if sha != row["sha256"]:
                        raise ReaderError("source_changed", "An indexed source no longer matches its live original bytes.")
                    snippet, location = _search_passage(row["body"], row["snippet"], markers, document_format(row["path"]))
                    matches.append({"path": row["path"], "sha256": sha, "snippet": snippet,
                                    "format": document_format(row["path"]), "location": location})
            final_inventory, final_total, _ = self._inventory()
            if inventory != final_inventory or total != final_total:
                raise ReaderError("source_changed", "The vault changed during the operation; no refreshed index was committed.")
            self._check_scope()
            self._check_root()
            snapshot = self._snapshot(inventory, total, counts, reads, len(matches))
            self._check_time()
            conn.execute("COMMIT")
            return {"snapshot": snapshot, **({"matches": matches} if query is not None else {})}
        except BaseException:
            conn.set_progress_handler(None, 0)
            if conn.in_transaction:
                try:
                    conn.execute("ROLLBACK")
                except sqlite3.Error:
                    pass  # Closing still rolls back; preserve the original error.
            raise
        finally:
            conn.close()

    def execute(self, command, *, query=None, path=None, limit=20, page=None, line=None):
        self._check_root()
        if (page is not None or line is not None) and command != "read":
            raise ReaderError("invalid_location", "Locations apply only to original reads.")
        if page is not None and line is not None:
            raise ReaderError("invalid_location", "Select either a page or a line.")
        if command == "vault":
            result = {}
        elif command == "read":
            self._load_scope()
            try:
                data, body, _ = self._read_bytes(path)
            except FileNotFoundError:
                raise ReaderError("not_found", "The requested original document was not found.") from None
            self._check_scope()
            self._check_root()
            result = {"path": path, "sha256": _digest(data), "bytes": len(data), "body": body}
            kind = document_format(path)
            result.update(format=kind, representation="extracted_text" if kind == "pdf" else "original_text")
            if kind == "pdf":
                pages = body.split("\f")
                result.update(page_count=len(pages), empty_pages=[i + 1 for i, text in enumerate(pages) if not text.strip()],
                              extractor="macOS PDFKit", limitations=["Text extraction only; scanned pages require OCR. Layout, images and equations may not survive extraction."])
                if page is not None:
                    if not 1 <= page <= len(pages):
                        raise ReaderError("invalid_location", "Choose an existing PDF page.")
                    result.update(body=pages[page - 1], location={"page": page})
                if line is not None:
                    raise ReaderError("invalid_location", "Use a page location for PDF documents.")
            elif page is not None:
                raise ReaderError("invalid_location", "Page locations apply only to PDFs.")
            elif line is not None:
                lines = body.splitlines(keepends=True)
                if not 1 <= line <= max(1, len(lines)):
                    raise ReaderError("invalid_location", "Choose an existing source line.")
                result.update(body="".join(lines[line - 1:line + 79]), location={"line": line}, total_lines=len(lines))
            result.update(body_sha256=_digest(result["body"].encode("utf-8")), body_bytes=len(result["body"].encode("utf-8")))
        elif command in {"search", "index"}:
            if command == "search":
                if not isinstance(query, str) or not query.strip() or len(query.encode("utf-8")) > MAX_QUERY_BYTES or "\x00" in query:
                    raise ReaderError("invalid_query", "A nonempty bounded FTS5 query is required.")
                if re.search(r"(?:^|\s|\()/[^\s]", query):
                    raise ReaderError("unsupported_query", "Regex queries are unsupported; use quoted terms and FTS5 operators.")
                if isinstance(limit, bool) or not isinstance(limit, int) or not 1 <= limit <= 100:
                    raise ReaderError("invalid_limit", "Search result limit must be between 1 and 100.")
            result = self._indexed(query if command == "search" else None, limit)
        else:
            raise ReaderError("invalid_arguments", "Unknown local reader command.")
        return {"schema": SCHEMA, "status": "ok", "vault": self.vault, "root": str(self.root), **result}


class _Parser(argparse.ArgumentParser):
    def error(self, message):
        raise ReaderError("invalid_arguments", "Invalid reader arguments; use --help for the supported interface.")


def read_source(vault, root, path, *, timeout=2.0, excluded_paths=(), formats=("markdown",)):
    """Read and revalidate current original bytes without touching any index.

    Returns the ordinary successful read packet. Raises ReaderError or OSError
    on failure; callers must not substitute cached evidence for either error.
    """
    with Reader(vault, root, timeout=timeout, excluded_paths=excluded_paths, formats=formats) as reader:
        return reader.execute("read", path=path)


def main(argv=None):
    try:
        parser = _Parser(description=__doc__)
        parser.add_argument("command", choices=("vault", "search", "read", "index"))
        parser.add_argument("--vault", required=True)
        parser.add_argument("--vault-root", required=True)
        parser.add_argument("--cache-root")
        parser.add_argument("--query")
        parser.add_argument("--path")
        parser.add_argument("--limit", type=int, default=20)
        parser.add_argument("--timeout", type=float, default=8.0)
        parser.add_argument("--exclude", action="append", default=[])
        parser.add_argument("--formats", default="markdown", help="Explicit comma-separated formats: markdown,tex,pdf,code,text,html")
        parser.add_argument("--page", type=int)
        parser.add_argument("--line", type=int)
        args = parser.parse_args(argv)
        with Reader(args.vault, args.vault_root, cache_root=args.cache_root, timeout=args.timeout,
                    excluded_paths=args.exclude, formats=args.formats.split(",")) as reader:
            payload = reader.execute(args.command, query=args.query, path=args.path, limit=args.limit, page=args.page, line=args.line)
    except ReaderError as error:
        payload = {"schema": SCHEMA, "status": "error", "error": {"code": error.code, "message": error.message}}
    except sqlite3.Error as error:
        text = str(error).lower()
        code = "index_busy" if "locked" in text or "busy" in text else "timeout" if "interrupted" in text else "index_error"
        payload = {"schema": SCHEMA, "status": "error", "error": {"code": code, "message": "The local search index could not complete the operation."}}
    except OSError:
        payload = {"schema": SCHEMA, "status": "error", "error": {"code": "filesystem_error", "message": "A required filesystem entry was inaccessible, unsafe, or changed during the operation."}}
    except (ValueError, TypeError, OverflowError):
        payload = {"schema": SCHEMA, "status": "error", "error": {"code": "invalid_arguments", "message": "The local reader received an invalid value."}}
    except Exception:  # noqa: BLE001 - CLI boundary emits safe JSON, never raw exception data
        payload = {"schema": SCHEMA, "status": "error", "error": {"code": "internal_error", "message": "The local reader could not safely complete the operation."}}
    print(_json(payload))
    return 0 if payload["status"] == "ok" else 1


if __name__ == "__main__":
    sys.exit(main())
