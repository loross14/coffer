#!/usr/bin/env python3
"""Fixture-only checks for read-only graph extraction; no live vault is opened."""
import importlib.util
import json
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch

PROJECT = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


G = load("graph_adapter", PROJECT / "Integrations/Grapheine/graph_adapter.py")
B = load("native_graph_bridge", PROJECT / "Integrations/Grapheine/bridge.py")


class GraphAdapterTests(unittest.TestCase):
    def graph(self, texts, **options):
        return G.build_graph(texts, "/vault", **options)

    def pairs(self, graph):
        return {(edge["source"], edge["target"]) for edge in graph["edges"]}

    def test_exact_paths_relative_links_deduplication_and_self_edges(self):
        result = self.graph({"A.md": "[[Folder/B]] [[Folder/B|B]] [[A]] [B](Folder/B.md)",
                             "Folder/B.md": "[A](../A.md) [[#Heading]]", "Empty.md": ""})
        self.assertEqual(self.pairs(result), {("A.md", "Folder/B.md"), ("Folder/B.md", "A.md"), ("A.md", "A.md")})
        nodes = {node["id"]: node for node in result["nodes"]}
        self.assertEqual((nodes["A.md"]["degree"], nodes["A.md"]["inDegree"], nodes["A.md"]["outDegree"]), (4, 2, 2))
        self.assertEqual(nodes["Empty.md"]["degree"], 0)

    def test_duplicate_stems_are_ambiguous_and_frontmatter_aliases_are_not_joined(self):
        result = self.graph({"Read.md": "[[Note]] [[Alias]] [[One/Note]] [relative](Two/Note.md)",
                             "One/Note.md": '---\naliases: [Alias, "[[Read]]"]\n---\n', "Two/Note.md": ""})
        self.assertEqual(self.pairs(result), {("Read.md", "One/Note.md"), ("Read.md", "Two/Note.md")})
        self.assertEqual(result["ambiguousLinkCount"], 1)
        self.assertEqual(result["unresolvedLinkCount"], 1)

    def test_code_comments_and_escaped_links_are_not_edges(self):
        literals = ["`[[B]]`", "``x ` [[B]] x``", "```md\n[[B]]\n```", "~~~\n[[B]]\n~~~",
                    "    [[B]]", "\t[[B]]", "<!-- [[B]] -->", "<pre>[[B]]</pre>",
                    "<code>[[B]]</code>", "\\[[B]]", "\\[B](B.md)", '---\na: "[[B]]"\n---']
        for literal in literals:
            with self.subTest(literal=literal):
                self.assertEqual(self.graph({"A.md": literal, "B.md": ""})["edges"], [])
        self.assertEqual(self.pairs(self.graph({"A.md": "\\` [[B]] \\`", "B.md": ""})), {("A.md", "B.md")})

    def test_dotted_stems_spaces_encoded_hash_and_parentheses(self):
        result = self.graph({"Sub/read.md": "[[note.v1]] [n](note.v1) [hash](<name%23part.md#heading>) [space](some%20note.md) [p](a(b).md)",
                             "Sub/note.v1.md": "", "Sub/name#part.md": "", "Sub/some note.md": "", "Sub/a(b).md": ""})
        self.assertEqual({target for _, target in self.pairs(result)},
                         {"Sub/note.v1.md", "Sub/name#part.md", "Sub/some note.md", "Sub/a(b).md"})

    def test_reference_markdown_and_external_links(self):
        result = self.graph({"Read.md": '[note][key] [key][] [key]\n\n[key]: Target.md "title"\n[web](https://example.com) [[image.png]] <a href="Target.md">HTML</a>',
                             "Target.md": ""})
        self.assertEqual(self.pairs(result), {("Read.md", "Target.md")})
        self.assertEqual(result["unsupportedLinkCount"], 1)
        self.assertEqual(result["unresolvedLinkCount"], 0)

    def test_absolute_inside_root_only_and_escape_paths(self):
        result = self.graph({"Read.md": "[inside](/vault/Sub/Note.md) [url](file:///vault/Sub/Note.md) [outside](/other/Note.md) [escape](../Note.md) [[Excluded/Note]]",
                             "Sub/Note.md": ""})
        self.assertEqual(self.pairs(result), {("Read.md", "Sub/Note.md")})
        self.assertEqual(result["unresolvedLinkCount"], 3)

    def test_empty_graph_and_deterministic_bounded_graph(self):
        empty = self.graph({})
        self.assertEqual((empty["totalNodeCount"], empty["totalEdgeCount"], empty["nodes"], empty["edges"]), (0, 0, [], []))
        texts = {f"N{i:05}.md": f"[[N{(i + 1) % 10001:05}]]" for i in range(10001)}
        result = self.graph(texts)
        self.assertEqual(len(result["nodes"]), 10000)
        self.assertEqual(result["omittedNodeCount"], 1)
        self.assertEqual(result["omittedEdgeCount"], 2)
        self.assertEqual(result["totalEdgeCount"], 10001)
        small = self.graph({"A.md": "[[B]] [[C]]", "B.md": "[[A]]", "C.md": ""}, edge_limit=1)
        self.assertEqual(small["edges"], [{"source": "A.md", "target": "B.md"}])
        self.assertEqual(small["omittedEdgeCount"], 2)
        self.assertEqual(sum(node["degree"] for node in small["nodes"]), 2)

    def test_malformed_links_are_linear_and_reported(self):
        start = time.monotonic()
        result = self.graph({"A.md": "[x](" * 10000, "B.md": ""})
        self.assertEqual(result["unsupportedLinkCount"], 10000)
        self.assertLess(time.monotonic() - start, 5, "40KB malformed input must not trigger repeated suffix scans")
        for token in ["[[", "[", "<", "<a "]:
            start = time.monotonic()
            self.graph({"A.md": token * 20000})
            self.assertLess(time.monotonic() - start, 5, "Unclosed delimiters must not trigger repeated suffix scans")
        self.assertEqual(self.graph({"A.md": "[plain] prose ](B.md)", "B.md": ""})["edges"], [])
        self.assertEqual(self.pairs(self.graph({"A.md": "[outer [inner] text](B.md)", "B.md": ""})), {("A.md", "B.md")})

    def test_occurrence_limit_is_an_explicit_failure(self):
        with patch.object(G, "MAX_LINK_OCCURRENCES", 2):
            with self.assertRaisesRegex(ValueError, "link occurrences"):
                self.graph({"A.md": "[[B]] [[B]] [[B]]", "B.md": ""})

    def test_bridge_scope_skips_hidden_dependencies_and_symlinks_without_authority_or_writes(self):
        with tempfile.TemporaryDirectory(prefix="planisphere-graph-test-", dir="/private/tmp") as tmp:
            root = Path(tmp)
            for folder in ["Notes", ".obsidian", ".hidden", "node_modules", "Ignored"]:
                (root / folder).mkdir()
            notes = {"Read.md": "[[Notes/Target]] [[linked]] [[Ignored/Target]]", "Notes/Target.md": "# Target\n"}
            for name, body in {**notes, ".hidden/Hidden.md": "[[Read]]", "Ignored/Target.md": "", "node_modules/Dependency.md": ""}.items():
                (root / name).write_text(body)
            (root / ".obsidian/app.json").write_text(json.dumps({"userIgnoreFilters": ["Ignored/"]}))
            (root / "linked.md").symlink_to(root / "Notes/Target.md")
            graph, _ = B.load_engine(PROJECT.parent / "Grapheine")
            with patch.object(B, "authority_scan", side_effect=AssertionError("graph must not inspect authority")):
                result = B.graph_snapshot(graph, root)
            self.assertEqual({node["id"] for node in result["nodes"]}, set(notes))
            self.assertEqual(self.pairs(result), {("Read.md", "Notes/Target.md")})
            self.assertEqual(result["unresolvedLinkCount"], 2)
            self.assertTrue({".hidden/", "node_modules/", "Ignored/", "linked.md"}.issubset(result["scope"]["excludedPaths"]))
            self.assertFalse((root / ".git").exists())
            for name, body in notes.items():
                self.assertEqual((root / name).read_text(), body)
            self.assertNotIn("# Target", json.dumps(result))


if __name__ == "__main__":
    unittest.main()
