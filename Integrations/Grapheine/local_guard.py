"""Conservative parser boundaries for locally reviewed pruning, with no file I/O.

These checks supplement the pinned engine; they do not establish semantic
equivalence, authority, or permission to edit a vault.
"""
from __future__ import annotations

from pathlib import Path
import json
import html
from html.parser import HTMLParser
import posixpath
import re
import unicodedata
from urllib.parse import unquote, urlsplit, parse_qs


def _escaped(text, index):
    count = 0
    while index > 0 and text[index - 1] == "\\":
        count += 1
        index -= 1
    return count % 2 == 1


def _without_code(text):
    """Mask ordinary fenced, indented and inline code without shifting offsets."""
    def blank(value):
        return "".join("\n" if c == "\n" else " " for c in value)
    parts, fence = [], None
    for line in text.splitlines(keepends=True):
        marker = re.match(r"^ {0,3}(`{3,}|~{3,})", line)
        if fence:
            parts.append(blank(line))
            if marker and marker[1][0] == fence[0] and len(marker[1]) >= fence[1] and not line[marker.end():].strip():
                fence = None
        elif marker:
            fence = (marker[1][0], len(marker[1]))
            parts.append(blank(line))
        elif line.startswith(("    ", "\t")):
            parts.append(blank(line))
        else:
            parts.append(line)
    masked = "".join(parts)
    return re.sub(r"(`+)(?!`)(.*?)\1(?!`)", lambda m: blank(m[0]), masked, flags=re.DOTALL)


def _markdown_links(text, tolerate_unclosed=False):
    """Yield destination text and label; retain unsupported forms for a hold."""
    consumed = 0
    for match in re.finditer(r"\]\(", text):
        if match.start() < consumed or _escaped(text, match.start()):
            continue
        opening = text.rfind("[", 0, match.start())
        if opening < 0 or _escaped(text, opening):
            continue
        cursor, depth = match.end(), 1
        while cursor < len(text) and depth:
            char = text[cursor]
            if not _escaped(text, cursor):
                if char == "(":
                    depth += 1
                elif char == ")":
                    depth -= 1
            cursor += 1
        if depth:
            if tolerate_unclosed:
                yield text[match.end():] + "\n", text[opening + 1:match.start()]
                return
            raise ValueError("An unclosed Markdown link needs review in the editor first")
        consumed = cursor
        yield text[match.end():cursor - 1], text[opening + 1:match.start()]


def _destination(raw):
    trimmed = raw.strip()
    if trimmed.startswith("<"):
        return trimmed[1:].partition(">")[0]
    return trimmed.split(maxsplit=1)[0] if trimmed else ""


def _is_url(destination):
    return bool(re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*:", destination)) or destination.startswith("//")


def _unsafe_local_reference(destination):
    decoded = unquote(destination)
    return ((decoded.startswith("/") and not decoded.startswith("//")) or decoded.startswith("~")
            or re.match(r"^(?:file|obsidian):", decoded, flags=re.IGNORECASE) is not None)


def _check_link(raw, label):
    destination = _destination(raw)
    if _unsafe_local_reference(destination):
        raise ValueError("Absolute, home-relative, file, or Obsidian links need review in the editor first")
    if _is_url(destination):
        return
    # The engine supports only bare local destinations, without Markdown titles,
    # angle brackets, escaped paths, nested parentheses, or multiline labels.
    if (not destination or raw != destination or any(c in raw for c in "<>\\()\r\n\t")
            or any(c in label for c in "[]\r\n")
            or any(c.isspace() for c in destination)):
        raise ValueError("Unsupported local Markdown link syntax needs review in the editor first")
    decoded = unquote(destination)
    if "?" in decoded and ".md" in decoded.lower():
        raise ValueError("Markdown note links with query parameters need review in the editor first")
    # The pinned engine's parser is case-sensitive and handles only .md paths.
    raw_path = destination.partition("#")[0]
    path = unquote(raw_path)
    if path.lower().endswith((".md", ".markdown")) and not path.endswith(".md"):
        raise ValueError("Unsupported Markdown note extension in a link needs review in the editor first")
    if path.endswith(".md") and not raw_path.endswith(".md"):
        raise ValueError("Encoded Markdown note extensions need review in the editor first")


def _validate_strict(texts: dict[str, str], root: Path) -> None:
    """Reject syntax the pinned preservation/retargeting parser cannot prove safe.

    Root identifies the caller's vault but is never resolved, probed or read.
    Supported ordinary links, attachment links, quoted prose and code examples
    remain available. The bridge must separately keep rewritten code byte-exact.
    """
    del root
    for name, text in texts.items():
        try:
            normalized = text.replace("\r\n", "\n")
            frontmatter = re.match(r"\A---\n(.*?)\n---(?:\n|$)", normalized, flags=re.DOTALL)
            if frontmatter:
                for owner in re.finditer(r"(?m)^\s*canonical_owner\s*:\s*(.*?)\s*$", frontmatter[1]):
                    raw = owner[1].strip().strip("\"").strip("'")
                    decoded = unquote(raw)
                    if (_unsafe_local_reference(raw) or ".." in decoded.split("/")
                            or raw.startswith(("[", "{", "|", ">")) or "\\" in decoded):
                        raise ValueError("Unsupported canonical_owner path needs review in the editor first")
            masked = _without_code(normalized)
            if re.search(r"<\s*(?:a|iframe|img|object|embed|area|link|source)\b", masked, flags=re.IGNORECASE):
                raise ValueError("HTML links or embeds need review in the editor first")
            if re.search(r"<[^>\n]+\b(?:href|src|xlink:href)\s*=", masked, flags=re.IGNORECASE):
                raise ValueError("HTML reference attributes need review in the editor first")
            if re.search(r"(?m)^\s{0,3}\[[^\]]+\]:", masked):
                raise ValueError("Reference-style links need review in the editor first")
            for wiki in re.finditer(r"(?<!\\)\[\[([^\]|#^\r\n]+)", masked):
                raw = unquote(wiki[1].strip())
                if _unsafe_local_reference(raw) or ".." in raw.split("/") or "\\" in raw:
                    raise ValueError("Unsupported absolute or parent-relative wiki link needs review in the editor first")
            for raw, label in _markdown_links(masked):
                _check_link(raw, label)
        except ValueError as exc:
            raise ValueError(f"{exc}: {name}") from exc


def _reference_key(value):
    return unicodedata.normalize("NFC", value).casefold()


def _might_target(raw, source, root, retired, aliases):
    """A conservative lexical match; no resolving or probing other paths."""
    raw = html.unescape(raw.strip().strip("\"").strip("'"))
    # Decode URL escaping, including an encoded file= query parameter.
    for _ in range(2):
        decoded = unquote(raw)
        if decoded == raw:
            break
        raw = decoded
    if not raw:
        return False
    destination = _destination(raw)
    try:
        url = urlsplit(destination)
    except ValueError:
        return True
    scheme = url.scheme.lower()
    if destination.startswith("//") or scheme in {"http", "https", "ftp", "ftps", "mailto", "tel", "data"}:
        return False
    if scheme == "obsidian":
        query = parse_qs(url.query)
        values = query.get("file", []) + query.get("path", [])
        return not values or any(_might_target(value, source, root, retired, aliases) for value in values)
    if scheme == "file":
        return _might_target(url.path, source, root, retired, aliases)
    if scheme:  # Unknown application/dynamic links cannot be resolved safely.
        return True
    if any(token in raw for token in ("{{", "${", "<%", "javascript:")):
        return True
    paths = {_reference_key(posixpath.normpath(path)) for path in retired}
    tokens = set()
    for path in retired:
        basename = posixpath.basename(path)
        tokens.update((_reference_key(basename), _reference_key(basename.removesuffix(".md"))))
    for alias in aliases:
        tokens.add(_reference_key(str(alias)))
    # Titles/angle brackets may be unsupported, but their destination is still
    # inspectable. Look at both the destination and full raw text for names with
    # spaces or otherwise ambiguous unsupported syntax.
    for candidate in (destination, raw):
        candidate = candidate.strip("<>").partition("#")[0].partition("?")[0]
        normalized = posixpath.normpath(candidate.replace("\\", "/"))
        choices = [normalized, posixpath.normpath(posixpath.join(posixpath.dirname(source), normalized))]
        if normalized.startswith(str(root).rstrip("/") + "/"):
            choices.append(normalized[len(str(root).rstrip("/")) + 1:])
        if normalized.startswith("/"):
            choices.append(normalized.lstrip("/"))
        if any(_reference_key(choice) in paths for choice in choices):
            return True
        basename = _reference_key(posixpath.basename(normalized))
        if basename in tokens or basename.removesuffix(".md") in tokens:
            return True
    key = _reference_key(raw)
    return any(token and re.search(r"(?<![\w.-])" + re.escape(token) + r"(?![\w.-])", key) for token in tokens)


class _HTMLReferences(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.targets = []

    def handle_starttag(self, tag, attrs):
        for name, value in attrs:
            if name in {"href", "src", "xlink:href", "data", "action", "srcdoc", "srcset"}:
                # Embedded or multiple destinations are deliberately ambiguous.
                self.targets.append(value if name not in {"srcdoc", "srcset"} else "${dynamic}")

    handle_startendtag = handle_starttag


def _validate_incoming(name, text, root, retired, aliases):
    normalized = text.replace("\r\n", "\n")
    masked = _without_code(normalized)
    may_target = lambda raw: _might_target(raw or "${unknown}", name, root, retired, aliases)
    frontmatter = re.match(r"\A---\n(.*?)\n---(?:\n|$)", normalized, flags=re.DOTALL)
    if frontmatter:
        for owner in re.finditer(r"(?m)^\s*canonical_owner\s*:\s*(.*?)\s*$", frontmatter[1]):
            if owner[1].strip() and may_target(owner[1]):
                raise ValueError("canonical_owner may refer to a retiring note; review it in the editor first")
    parser = _HTMLReferences()
    parser.feed(masked)
    parser.close()
    if any(may_target(value) for value in parser.targets):
        raise ValueError("An HTML reference may target a retiring note; review it in the editor first")
    for incomplete in re.finditer(r"<\s*(?:a|iframe|img|object|embed|area|link|source)\b[^>]*\Z", masked, flags=re.IGNORECASE):
        if may_target(incomplete[0]):
            raise ValueError("An incomplete HTML reference may target a retiring note; review it in the editor first")
    for definition in re.finditer(r"(?m)^\s{0,3}\[[^\]]+\]:[ \t]*(.*)$", masked):
        if not definition[1].strip() or may_target(definition[1]):
            raise ValueError("A reference-style link may target a retiring note; review it in the editor first")
    for wiki in re.finditer(r"(?<!\\)\[\[([^\]|#^\r\n]+)", masked):
        raw = unquote(wiki[1].strip())
        if (_unsafe_local_reference(raw) or ".." in raw.split("/") or "\\" in raw) and may_target(raw):
            raise ValueError("An unsupported wiki link may target a retiring note; review it in the editor first")
    for raw, label in _markdown_links(masked, tolerate_unclosed=True):
        try:
            _check_link(raw, label)
        except ValueError:
            if may_target(raw):
                raise ValueError("An unsupported Markdown link may target a retiring note; review it in the editor first")


def validate_local_markdown(texts: dict[str, str], root: Path, members=None, retired=None, retired_aliases=None) -> None:
    """Keep strict outgoing checks on the chosen family, targeted checks elsewhere.

    Unrelated documentation is not a global veto. Unsupported incoming syntax
    is held when it can refer to a retiring path/name/alias or cannot be resolved
    conservatively. Omitting members retains the original strict-all behavior.
    The bridge must still compare code literals after planning actual rewrites.
    """
    if members is None:
        return _validate_strict(texts, root)
    family = set(members)
    if retired is None or not set(retired).issubset(family) or not family.issubset(texts):
        raise ValueError("Local parser review requires explicit present members and retirements")
    _validate_strict({name: texts[name] for name in family}, root)
    for name, text in texts.items():
        if name not in family:
            try:
                _validate_incoming(name, text, root, set(retired), retired_aliases or [])
            except ValueError as exc:
                raise ValueError(f"{exc}: {name}") from exc


def local_attachment_references(text: str, source_path: str = "") -> set[str]:
    """Return logical Markdown attachment destinations, never target contents.

    Destinations resolve lexically relative to each note, so identical relative
    strings in different folders are not mistaken for the same evidence. URLs
    retain their raw destination/title form. Call validation before this helper.
    """
    result = set()
    for raw, label in _markdown_links(_without_code(text.replace("\r\n", "\n"))):
        _check_link(raw, label)
        destination = _destination(raw)
        if _is_url(destination):
            result.add("url:" + raw)
            continue
        raw_path, separator, raw_fragment = destination.partition("#")
        path, fragment = unquote(raw_path), unquote(raw_fragment) if separator else None
        if path.endswith(".md"):
            continue  # The engine checks note links and anchors separately.
        logical = posixpath.normpath(posixpath.join(posixpath.dirname(source_path), path))
        # A structured string avoids equating a literal encoded '#' in a file
        # name with a fragment delimiter in a different reference.
        result.add("local:" + json.dumps([logical, fragment], ensure_ascii=False, separators=(",", ":")))
    return result
