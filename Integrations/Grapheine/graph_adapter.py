"""Read-only graph extraction from already admitted Markdown text.

This module never opens files. IDs are exact relative note paths, not stems.
"""
from collections import Counter, defaultdict
import posixpath
import re
from urllib.parse import unquote, urlsplit

MAX_GRAPH_NODES = 10_000
MAX_GRAPH_EDGES = 100_000
MAX_LINK_OCCURRENCES = 1_000_000
GRAPH_LIMITATIONS = [
    "Graph content is limited to the included Markdown discovery scope; excluded files, symlinks, attachments and other vaults are not nodes.",
    "Wikilinks use exact paths or an unambiguous note basename. Markdown paths resolve relative to the source note. Frontmatter aliases are not inferred.",
    "Fenced, inline, indented and HTML code, HTML comments and YAML frontmatter do not create edges. Reference-style Markdown links are supported; HTML links are counted as unsupported.",
    "Heading-only links stay within a note and are omitted. Explicit links to the source note are retained as self-edges. Repeated source-to-target links form one directed edge.",
    "Missing and ambiguous counts describe link occurrences across the complete admitted Markdown scope. Degrees describe only returned edges.",
]


def _blank(value):
    return "".join("\n" if c == "\n" else " " for c in value)


def _escaped(text, index):
    count = 0
    while index > 0 and text[index - 1] == "\\":
        count += 1
        index -= 1
    return count % 2 == 1


def _mask(text):
    text = text.replace("\r\n", "\n")
    # Metadata is not prose. Aliases must not quietly collapse distinct nodes.
    text = re.sub(r"\A\ufeff?---[ \t]*\n(?:.*?\n)?(?:---|\.\.\.)[ \t]*(?:\n|$)", lambda m: _blank(m[0]), text, count=1, flags=re.S)
    text = re.sub(r"<(pre|code)\b[^<>]*>.*?(?:</\1\s*>|\Z)", lambda m: _blank(m[0]), text, flags=re.I | re.S)
    parts, fence = [], None
    for line in text.splitlines(keepends=True):
        marker = re.match(r"^ {0,3}(`{3,}|~{3,})", line)
        if fence:
            parts.append(_blank(line))
            if marker and marker[1][0] == fence[0] and len(marker[1]) >= fence[1] and not line[marker.end():].strip():
                fence = None
        elif marker:
            fence = (marker[1][0], len(marker[1]))
            parts.append(_blank(line))
        elif line.startswith(("    ", "\t")):
            parts.append(_blank(line))
        else:
            parts.append(line)
    text = "".join(parts)
    tokens = list(re.finditer(r"`+", text))
    following, last = {}, {}
    for i in range(len(tokens) - 1, -1, -1):
        length = len(tokens[i][0])
        if length in last:
            following[i] = last[length]
        last[length] = i
    spans, i = [], 0
    while i < len(tokens):
        if i in following and not _escaped(text, tokens[i].start()):
            end = following[i]
            spans.append((tokens[i].start(), tokens[end].end()))
            i = end + 1
        else:
            i += 1
    text = _erase(text, spans)
    return re.sub(r"<!--.*?(?:-->|\Z)", lambda m: _blank(m[0]), text, flags=re.S)


def _erase(text, spans):
    result, cursor = [], 0
    for start, end in sorted(spans):
        if start < cursor:
            continue
        result.extend((text[cursor:start], _blank(text[start:end])))
        cursor = end
    result.append(text[cursor:])
    return "".join(result)


def _destination(raw):
    raw = raw.strip()
    if raw.startswith("<"):
        end = raw.find(">", 1)
        if end < 0:
            return None
        destination, tail = raw[1:end], raw[end + 1:].strip()
    else:
        match = re.match(r"(?:\\.|[^\s])+", raw)
        if not match:
            return None
        destination, tail = match[0], raw[match.end():].strip()
    if tail and not ((tail[0] == tail[-1] and tail[0] in "\"'") or (tail.startswith("(") and tail.endswith(")"))):
        return None
    return re.sub(r"\\([!\"#$%&'()*+,\-./:;<=>?@\[\]^_`{|}~\\])", r"\1", destination)


def links(text):
    """Return (kind, raw destination) occurrences and unsupported count."""
    text = _mask(text)
    references, spans, unsupported = {}, [], 0
    for match in re.finditer(r"(?m)^ {0,3}\[([^\[\]\n]+)\]:[ \t]*(.+)$", text):
        key = " ".join(match[1].split()).casefold()
        if key not in references:
            references[key] = _destination(match[2])
        spans.append(match.span())
    text = _erase(text, spans)
    html = list(re.finditer(r"<\s*(?:a|img|iframe|object|embed|area|link|source)\b[^<>]*>|<[^<>\n]+\b(?:href|src|xlink:href)\s*=[^<>]*>", text, re.I))
    unsupported += len(html)
    text = _erase(text, [m.span() for m in html])
    result, spans = [], []
    for match in re.finditer(r"\[\[([^\[\]\r\n]+)\]\]", text):
        spans.append(match.span())
        if not _escaped(text, match.start()):
            destination = re.split(r"(?<!\\)\|", match[1], maxsplit=1)[0].strip()
            result.append(("wiki", destination))
    text = _erase(text, spans)
    # Pair parentheses once. Repeated malformed '[x](' text must not rescan the
    # entire remaining note for each unmatched opener.
    closes, stack, escaped = {}, [], False
    for index, char in enumerate(text):
        if escaped:
            escaped = False
            continue
        if char == "\\":
            escaped = True
        elif char == "(":
            stack.append(index)
        elif char == ")" and stack:
            closes[stack.pop()] = index
    spans, consumed, brackets = [], 0, []
    for match in re.finditer(r"\[|\]", text):
        if match.start() < consumed or _escaped(text, match.start()):
            continue
        if match[0] == "[":
            brackets.append(match.start())
            continue
        opening = brackets.pop() if brackets else -1
        if opening < 0 or text[match.end():match.end() + 1] != "(":
            continue
        end = closes.get(match.end())
        if end is None:
            unsupported += 1
            continue
        cursor = end + 1
        consumed = cursor
        spans.append((opening, cursor))
        destination = _destination(text[match.end() + 1:cursor - 1])
        if destination is None:
            unsupported += 1
        else:
            result.append(("markdown", destination))
    text = _erase(text, spans)
    spans = []
    for match in re.finditer(r"\[([^\[\]\n]+)\][ \t]*\[([^\[\]\n]*)\]", text):
        spans.append(match.span())
        if _escaped(text, match.start()):
            continue
        key = " ".join((match[2] or match[1]).split()).casefold()
        if key in references and references[key] is not None:
            result.append(("markdown", references[key]))
        else:
            unsupported += 1
    text = _erase(text, spans)
    for match in re.finditer(r"\[([^\[\]\n]+)\]", text):
        key = " ".join(match[1].split()).casefold()
        if not _escaped(text, match.start()) and key in references:
            if references[key] is not None:
                result.append(("markdown", references[key]))
            else:
                unsupported += 1
    return result, unsupported


def build_graph(texts, vault_path, *, node_limit=MAX_GRAPH_NODES, edge_limit=MAX_GRAPH_EDGES):
    paths = set(texts)
    by_name = defaultdict(set)
    for path in paths:
        by_name[posixpath.basename(path)].add(path)
    edges, unresolved, ambiguous, unsupported = set(), 0, 0, 0

    def resolve(source, kind, raw):
        if not raw or raw.startswith(("#", "^")):
            return None, "ignored"
        parts = urlsplit(raw)
        if parts.scheme:
            if parts.scheme.casefold() != "file":
                return None, "unsupported" if parts.scheme.casefold() == "obsidian" else "ignored"
            if parts.netloc not in ("", "localhost"):
                return None, "unresolved"
            raw_path = parts.path
        elif raw.startswith("//"):
            return None, "ignored"
        else:
            raw_path = raw.split("#", 1)[0].split("?", 1)[0]
        target = unquote(raw_path, errors="strict")
        if not target or "\\" in target or "\x00" in target:
            return None, "unsupported"
        if target.startswith("/"):
            normalized = posixpath.normpath(target)
            prefix = vault_path.rstrip("/") + "/"
            if not normalized.startswith(prefix):
                return None, "unresolved"
            target = normalized[len(prefix):]
            kind = "root"
        if target.startswith("~"):
            return None, "unsupported"
        suffix = posixpath.splitext(target)[1]
        # Attachments do not become invented note nodes. Wikilinks may name a
        # real dotted stem, but only when it is present in the admitted set.
        missing_state = "ignored" if suffix and suffix != ".md" else "unresolved"
        target = target if target.endswith(".md") else target + ".md"
        if kind == "markdown" or target.startswith(("./", "../")):
            candidate = posixpath.normpath(posixpath.join(posixpath.dirname(source), target))
            return (candidate, "found") if candidate in paths else (None, missing_state)
        candidate = posixpath.normpath(target)
        if candidate.startswith("../") or candidate == "..":
            return None, "unresolved"
        if "/" in target or kind == "root":
            return (candidate, "found") if candidate in paths else (None, missing_state)
        matches = by_name.get(candidate, set())
        if len(matches) == 1:
            return next(iter(matches)), "found"
        return None, "ambiguous" if matches else missing_state

    occurrence_count = 0
    for source in sorted(paths):
        occurrences, unknown = links(texts[source])
        occurrence_count += len(occurrences) + unknown
        if occurrence_count > MAX_LINK_OCCURRENCES:
            raise ValueError("Graph exceeds the supported 1,000,000 link occurrences. Narrow the vault's Markdown exclusions and try again.")
        unsupported += unknown
        for kind, destination in occurrences:
            try:
                target, state = resolve(source, kind, destination)
            except ValueError:
                target, state = None, "unsupported"
            if state == "found":
                edges.add((source, target))
            elif state == "ambiguous":
                ambiguous += 1
            elif state == "unresolved":
                unresolved += 1
            elif state == "unsupported":
                unsupported += 1
    selected = sorted(paths)[:node_limit]
    included = set(selected)
    shown_edges = sorted(pair for pair in edges if pair[0] in included and pair[1] in included)[:edge_limit]
    inbound, outbound = Counter(target for _, target in shown_edges), Counter(source for source, _ in shown_edges)
    nodes = [{"id": path, "title": posixpath.basename(path)[:-3], "folder": posixpath.dirname(path),
              "degree": inbound[path] + outbound[path], "inDegree": inbound[path], "outDegree": outbound[path]} for path in selected]
    limitations = list(GRAPH_LIMITATIONS)
    if len(selected) < len(paths):
        limitations.append(f"Showing the first {len(selected):,} of {len(paths):,} notes by exact path; remaining notes are omitted from this view.")
    if len(shown_edges) < len(edges):
        limitations.append(f"Showing {len(shown_edges):,} of {len(edges):,} unique directed links due to node/edge limits.")
    return {"nodes": nodes, "edges": [{"source": source, "target": target} for source, target in shown_edges],
            "totalNodeCount": len(paths), "totalEdgeCount": len(edges),
            "omittedNodeCount": len(paths) - len(selected), "omittedEdgeCount": len(edges) - len(shown_edges),
            "unresolvedLinkCount": unresolved, "ambiguousLinkCount": ambiguous,
            "unsupportedLinkCount": unsupported, "limits": limitations}
