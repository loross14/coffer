#!/usr/bin/env python3
"""Fixture-only checks for read-only graph extraction; no live vault is opened."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch

PROJECT = Path(__file__).resolve().parents[1]
import argparse
import sys
_parser = argparse.ArgumentParser(add_help=False)
_parser.add_argument("--engine-root", type=Path, default=PROJECT.parent / "Grapheine")
_known, _remaining = _parser.parse_known_args()
ENGINE = _known.engine_root.resolve()
sys.argv = [sys.argv[0], *_remaining]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


G = load("graph_adapter", PROJECT / "Integrations/Grapheine/graph_adapter.py")
B = load("native_graph_bridge", PROJECT / "Integrations/Grapheine/bridge.py")
ENGINE_MODULE, _ = B.load_engine(ENGINE)


class GraphAdapterTests(unittest.TestCase):
    def graph(self, texts, **options):
        return G.build_graph(texts, "/vault", engine=ENGINE_MODULE, **options)

    def pairs(self, graph):
        return {(edge["source"], edge["target"]) for edge in graph["edges"]}

    def test_exact_paths_relative_links_deduplication_and_ignored_self_links(self):
        result = self.graph({"A.md": "[[Folder/B]] [[Folder/B|B]] [[A]] [B](Folder/B.md)",
                             "Folder/B.md": "[A](../A.md) [[#Heading]]", "Empty.md": ""})
        self.assertEqual(self.pairs(result), {("A.md", "Folder/B.md"), ("Folder/B.md", "A.md")})
        nodes = {node["id"]: node for node in result["nodes"]}
        self.assertEqual((nodes["A.md"]["degree"], nodes["A.md"]["inDegree"], nodes["A.md"]["outDegree"]), (2, 1, 1))
        self.assertEqual(nodes["Empty.md"]["degree"], 0)

    def test_duplicate_stems_resolve_by_shortest_path_and_count_as_ambiguous(self):
        result = self.graph({"Read.md": "[[Note]] [[Alias]] [[One/Note]] [relative](Two/Note.md) [[Nowhere]]",
                             "One/Note.md": '---\naliases: [Alias, "[[Read]]"]\n---\n', "Two/Note.md": ""})
        self.assertEqual(self.pairs(result), {("Read.md", "One/Note.md"), ("Read.md", "Two/Note.md")})
        self.assertEqual(result["ambiguousLinkCount"], 1)   # [[Note]] tie-broken to One/Note.md
        self.assertEqual(result["unresolvedLinkCount"], 1)  # [[Nowhere]]; [[Alias]] now resolves through frontmatter

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

    def test_document_graph_resolves_explicit_tex_and_does_not_invent_code_or_ambiguous_edges(self):
        with tempfile.TemporaryDirectory(prefix="planisphere-doc-graph-", dir="/private/tmp") as tmp:
            root = Path(tmp)
            sources = {
                "Read.md": "[code](model.py) [paper](paper.pdf)",
                "Main.TEX": r"\input{proof}\ref{unique}\ref{duplicate}\ref{missing}" + "\n" + r"% \ref{commented}",
                "proof.tex": r"\label{unique}\label{duplicate}",
                "other.tex": r"\label{duplicate}",
                "example.tex": r"\begin{verbatim}\ref{unique}\end{verbatim}",
                "model.py": "# [[Read]]\nimport proof\n",
                "paper.pdf": "%PDF- graph must not extract PDF text",
            }
            for name, body in sources.items():
                (root / name).write_text(body)
            graph, _ = B.load_engine(ENGINE)
            result = B.graph_snapshot(graph, root, documents=True)
            self.assertEqual({node["id"] for node in result["nodes"]}, set(sources))
            self.assertEqual(self.pairs(result), {("Read.md", "model.py"), ("Read.md", "paper.pdf"), ("Main.TEX", "proof.tex")})
            self.assertEqual(result["ambiguousLinkCount"], 1)
            self.assertEqual(result["unresolvedLinkCount"], 1)
            default = B.graph_snapshot(graph, root)
            self.assertEqual({node["id"] for node in default["nodes"]}, {"Read.md"})
            for name, body in sources.items():
                self.assertEqual((root / name).read_text(), body)

    def test_tex_literal_examples_do_not_create_links_or_label_owners(self):
        literals = [r"\verb|\ref{target}|", r"\verb*+\input{Target}+", r"\\ref{target}",
                    r"\begin{verbatim}\ref{target}", r"\begin{lstlisting}\ref{target}\end{lstlisting}",
                    r"\begin{Verbatim}\ref{target}\end{Verbatim}",
                    r"\begin{minted}{tex}\ref{target}\end{minted}",
                    r"\\% \ref{target}", r"\verb%\ref{target}%", r"\verb|unclosed \ref{target}",
                    r"\verb|\label{target}|", r"\\label{target}"]
        with tempfile.TemporaryDirectory(prefix="planisphere-tex-literals-", dir="/private/tmp") as tmp:
            root = Path(tmp)
            (root / "Target.tex").write_text(r"\label{target}")
            (root / "Real.tex").write_text(r"\% real percent \ref{target}" + "\n" + r"\\\ref{target}")
            for index, literal in enumerate(literals):
                (root / f"Example{index}.tex").write_text(literal)
            graph, _ = B.load_engine(ENGINE)
            result = B.graph_snapshot(graph, root, documents=True)
            self.assertEqual(self.pairs(result), {("Real.tex", "Target.tex")})
            self.assertEqual(result["ambiguousLinkCount"], 0)
            self.assertEqual(result["unresolvedLinkCount"], 0)
        # Real references following a closed literal or a newline remain visible.
        for literal in [r"\verb|\ref{fake}|", r"\verb|unclosed", "% comment", r"\\% comment"]:
            clean = B.tex_link_source(literal + "\n" + r"\ref{real}")
            self.assertEqual([m[1] for m in graph.TEX_REF_RE.finditer(clean)], ["real"])

    def test_tex_many_comments_and_literals_are_bounded(self):
        source = (r"\verb|\ref{fake}| % \ref{fake}" + "\n") * 20000 + r"\ref{real}"
        start = time.monotonic()
        clean = B.tex_link_source(source)
        self.assertEqual(clean.count(r"\ref"), 1)
        self.assertEqual(len(clean), len(source))
        self.assertLess(time.monotonic() - start, 5)

    def test_failed_document_search_does_not_break_markdown_reading_or_pruning(self):
        with tempfile.TemporaryDirectory(prefix="planisphere-reader-compat-", dir="/private/tmp") as tmp:
            root = Path(tmp) / "vault"
            root.mkdir()
            sources = {"Read.md": "# Local note\nsafeneedle\n", "broken.pdf": "Not a PDF",
                       "model.py": "raise RuntimeError('Source must never execute')"}
            for name, body in sources.items():
                (root / name).write_text(body)
            graph, authority = B.load_engine(ENGINE)
            with patch.dict(os.environ, {"PLANISPHERE_READER_CACHE": str(Path(tmp) / "cache")}):
                for after_document_failure in (False, True):
                    if after_document_failure:
                        with self.assertRaisesRegex(Exception, "PDF"):
                            B.document_operation(root, "search-documents", query="safeneedle")
                    result = B.document_operation(root, "search-documents", query="safeneedle", documents=False)
                    self.assertEqual([hit["path"] for hit in result["matches"]], ["Read.md"])
                    read = B.document_operation(root, "read-document", path="Read.md", documents=False)
                    self.assertEqual(read["body"], sources["Read.md"])
                    self.assertEqual({node["id"] for node in B.graph_snapshot(graph, root)["nodes"]}, {"Read.md"})
                    self.assertEqual(B.scan(graph, authority, root, None)["notes"], 1)
                read = B.document_operation(root, "read-document", path="model.py")
                self.assertEqual(read["body"], sources["model.py"])
            self.assertEqual({p.name for p in root.iterdir()}, set(sources))
            for name, body in sources.items():
                self.assertEqual((root / name).read_text(), body)

    def test_bridge_scope_skips_hidden_dependencies_and_symlinks_without_authority_or_writes(self):
        with tempfile.TemporaryDirectory(prefix="planisphere-graph-test-", dir="/private/tmp") as tmp:
            root = Path(tmp)
            for folder in ["Notes", ".planisphere", ".hidden", "node_modules", "Ignored"]:
                (root / folder).mkdir()
            notes = {"Read.md": "[[Notes/Target]] [[linked]] [[Ignored/Target]]", "Notes/Target.md": "# Target\n"}
            for name, body in {**notes, ".hidden/Hidden.md": "[[Read]]", "Ignored/Target.md": "", "node_modules/Dependency.md": ""}.items():
                (root / name).write_text(body)
            (root / ".planisphere/scope.json").write_text(json.dumps({"excludedPaths": ["Ignored/"]}))
            (root / "linked.md").symlink_to(root / "Notes/Target.md")
            graph, _ = B.load_engine(ENGINE)
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
