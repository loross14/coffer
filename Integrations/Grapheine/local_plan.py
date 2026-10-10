"""Git-free local planning using the pinned engine's preservation primitives.

The bridge supplies only a private, verified Markdown copy. Its target-aware
syntax guard has already refused unsupported references to retiring notes.
Unlike the legacy writer, unrelated HTML/reference-style links do not hold
every possible local operation. This module never writes files.
"""
import os
from urllib.parse import quote


def make_local_changes(graph, authority, root, members, keep, notes):
    family, retired = set(members), set(members) - {keep}
    if keep not in notes or not family.issubset(notes):
        raise ValueError("Every reviewed account must exist in the Markdown scope.")
    texts = {name: (root / name).read_bytes().decode("utf-8") for name in notes}
    for name in family:
        body, metadata = graph.read_note(root / name)
        if graph._affect_gate(root / name, body, metadata, {})["charge"] or metadata.get("affect_hold") in ("true", "yes", True):
            raise ValueError("G4: affect hold: " + name)
    kept_references = authority.refs(root, keep, texts[keep], notes, family)
    for name in retired:
        if authority.refs(root, name, texts[name], notes, family) - kept_references:
            raise ValueError("G5: unique evidence would leave the active answer: " + name)
    changes = {name: None for name in retired}
    for name, text in texts.items():
        if name in retired:
            continue
        _, metadata = graph.read_note(root / name)
        owner = str(metadata.get("canonical_owner", "")).strip()
        try:
            owner_target = authority._wiki_target(root, name, owner, notes) if owner else None
        except authority.AmbiguousLink as exc:
            if exc.candidates & retired:
                raise
            owner_target = None
        if owner_target in retired:
            raise ValueError("G5: canonical_owner points at a retiring note: " + name)
        edits = []
        for match, target, fragment, kind in authority.links(root, name, text, notes, relevant=retired):
            if target not in retired:
                continue
            if fragment:
                raise ValueError("G5: anchored reference needs preservation review: " + name)
            if kind == "wiki":
                replacement = "[[" + keep[:-3] + (match["pipe"] or "|" + match["stem"]) + "]]"
            else:
                href = quote(os.path.relpath(root / keep, (root / name).parent).replace(os.sep, "/"), safe="/")
                replacement = "[" + match["label"] + "](" + href + ")"
            edits.append((match.start(), match.end(), replacement))
        if edits:
            body, metadata = graph.read_note(root / name)
            if graph._affect_gate(root / name, body, metadata, {})["charge"] or metadata.get("affect_hold") in ("true", "yes", True):
                raise ValueError("G4: affected referring note is held: " + name)
            for start, end, replacement in reversed(edits):
                text = text[:start] + replacement + text[end:]
            changes[name] = text
    return changes
