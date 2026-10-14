"""Read-only graph extraction from already admitted Markdown text.

This module never opens files. IDs are exact relative note paths, not stems.
Link parsing and resolution come from the reviewed Grapheine engine
(`parse_links`, `resolve_link`, `LINK_RULE`), so the app's graph view and
`grapheine health` count the same edges. This module keeps admission, limits
and the document (TeX) extras.
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
    "Links resolve under Grapheine's single rule: exact vault-relative path when the destination contains '/', source-relative for './' and '../', otherwise note basename or frontmatter alias (case-insensitive); duplicate basenames resolve to the same folder, then the shortest path, and are counted as ambiguous. Markdown paths resolve relative to the source note.",
    "Fenced, inline, indented and HTML code, HTML comments and YAML frontmatter do not create edges. Reference-style Markdown links are supported; HTML links are counted as unsupported.",
    "Heading-only links stay within a note and are omitted. Links to the source note itself are ignored. Repeated source-to-target links form one directed edge.",
    "Missing and ambiguous counts describe link occurrences across the complete admitted Markdown scope. Degrees describe only returned edges.",
]


def _aliases(text):
    match = re.match(r"\A\ufeff?---[ \t]*\n(.*?)\n(?:---|\.\.\.)[ \t]*(?:\n|$)", text.replace("\r\n", "\n"), re.S)
    if not match:
        return []
    out, block = [], match[1]
    for key in ("aliases", "alias"):
        found = re.search(r"(?m)^" + key + r":[ \t]*(.*)$", block)
        if not found:
            continue
        value = found[1].strip()
        if value.startswith("["):
            out += [v.strip().strip("\"'") for v in value.strip("[]").split(",") if v.strip()]
        elif value:
            out += [v.strip().strip("\"'") for v in re.split(r"[,]", value) if v.strip()]
        else:
            tail = block[found.end():]
            for line in tail.splitlines():
                item = re.match(r"^[ \t]+-[ \t]*(.+)$", line)
                if not item:
                    break
                out.append(item[1].strip().strip("\"'"))
    return [a for a in out if a]


def links(text, engine):
    """(kind, destination) occurrences and the unsupported count, from the engine's parser."""
    return engine.parse_links(text)


def build_graph(texts, vault_path, *, engine, node_limit=MAX_GRAPH_NODES, edge_limit=MAX_GRAPH_EDGES, formats=None, extra_links=None):
    paths = set(texts)
    by_name = defaultdict(set)
    for path in paths:
        if path.endswith(".md"):
            by_name[posixpath.basename(path)[:-3].casefold()].add(path)
            for alias in _aliases(texts[path]) if (not formats or formats[path] == "markdown") else ():
                by_name[alias.casefold()].add(path)
    path_map = {path: path for path in paths}
    edges, unresolved, ambiguous, unsupported = set(), 0, 0, 0

    def resolve(source, kind, raw):
        nonlocal ambiguous
        tie_broken = []

        def prefer(candidates):
            pool = sorted(candidates, key=lambda c: (posixpath.dirname(c) != posixpath.dirname(source), len(c), c))
            tie_broken.append(pool[0])
            return pool[0]

        if kind == "root":
            return (raw, "found") if raw in paths else (None, "unresolved")
        if kind == "markdown":
            explicit = posixpath.normpath(posixpath.join(posixpath.dirname(source), unquote(raw.split("#", 1)[0].split("?", 1)[0], errors="replace")))
            if formats and explicit in paths:
                return explicit, "found"
            parts = urlsplit(raw)
            if parts.scheme and parts.scheme.casefold() == "file":
                raw = parts.path
            if raw.startswith("/"):
                normalized = posixpath.normpath(raw)
                prefix = vault_path.rstrip("/") + "/"
                if not normalized.startswith(prefix):
                    return None, "unresolved"
                raw = "/" + normalized[len(prefix):]
        target, state = engine.resolve_link(kind, raw, source, path_map, by_name, prefer)
        if state == "found" and tie_broken:
            ambiguous += 1
        return target, state

    occurrence_count = 0
    for source in sorted(paths):
        occurrences, unknown = links(texts[source], engine) if not formats or formats[source] == "markdown" else ([], 0)
        occurrences += (extra_links or {}).get(source, [])
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
                if target != source:
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
    nodes = [{"id": path, "title": posixpath.splitext(posixpath.basename(path))[0], "folder": posixpath.dirname(path),
              "degree": inbound[path] + outbound[path], "inDegree": inbound[path], "outDegree": outbound[path]} for path in selected]
    limitations = list(GRAPH_LIMITATIONS)
    if formats:
        limitations[0] = "Includes explicitly selected Markdown, TeX, PDF, code, text and HTML formats within the same Planisphere exclusions. Reading does not expand checkpoint or pruning scope."
        limitations.append("Edges use explicit Markdown destinations and TeX references/includes. PDF and code contents do not create inferred dependency edges. TeX macros are not executed or expanded.")
    if len(selected) < len(paths):
        limitations.append(f"Showing the first {len(selected):,} of {len(paths):,} notes by exact path; remaining notes are omitted from this view.")
    if len(shown_edges) < len(edges):
        limitations.append(f"Showing {len(shown_edges):,} of {len(edges):,} unique directed links due to node/edge limits.")
    return {"nodes": nodes, "edges": [{"source": source, "target": target} for source, target in shown_edges],
            "totalNodeCount": len(paths), "totalEdgeCount": len(edges),
            "omittedNodeCount": len(paths) - len(selected), "omittedEdgeCount": len(edges) - len(shown_edges),
            "unresolvedLinkCount": unresolved, "ambiguousLinkCount": ambiguous,
            "unsupportedLinkCount": unsupported, "limits": limitations}
