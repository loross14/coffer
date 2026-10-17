#!/usr/bin/env python3
"""Read-only local pruning proposals on disposable non-Git vaults."""
import base64
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from unittest.mock import patch

sys.dont_write_bytecode = True
PROJECT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("local_bridge", PROJECT / "Integrations/Grapheine/bridge.py")
B = importlib.util.module_from_spec(spec)
spec.loader.exec_module(B)
ENGINE = PROJECT.parent / "Grapheine"


class LocalPruningTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="planisphere-local-pruning-", dir="/private/tmp")
        self.base = Path(self.temporary.name)
        self.root = self.base / "Ordinary Vault"
        self.root.mkdir()
        self.G, self.A = B.load_engine(ENGINE)
        self.members = ["Current/Record.md", "Archive/Record.md"]
        self.write(self.members[0], "# Current\n[[evidence]]\n")
        self.write(self.members[1], "# Earlier\n[[evidence]]\n")
        self.write("evidence.md", "# Evidence\n")
        self.write("reader.md", "Read [[Archive/Record|earlier]] or [earlier](Archive/Record.md).\n")

    def tearDown(self):
        self.temporary.cleanup()

    def write(self, name, text):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def scan(self):
        return B.scan(self.G, self.A, self.root)

    def prepare(self, members=None, keep=None, fingerprint=None):
        return B.prepare_local(self.G, self.A, self.root,
                               members if members is not None else self.members,
                               keep or self.members[0], fingerprint or self.scan()["fingerprint"])

    def verify(self, packet):
        path = self.base / "review.json"
        path.write_text(json.dumps(packet), encoding="utf-8")
        return B.verify_local(self.G, self.A, self.root, path)

    def test_review_and_verification_need_no_git_or_signer_and_do_not_write(self):
        before = {str(p.relative_to(self.root)): p.read_bytes() for p in self.root.rglob("*.md")}
        with patch.object(self.A, "git", side_effect=AssertionError("Git must not be called")):
            packet = self.prepare()
            self.assertEqual(self.verify(packet), packet)
        payload = packet["packet"]
        self.assertEqual(payload["schema"], B.LOCAL_SCHEMA)
        self.assertEqual(payload["scope"]["version"], 4)
        self.assertIsNone(payload["changes"]["Archive/Record.md"])
        self.assertIn("[[Current/Record|earlier]]", payload["changes"]["reader.md"])
        self.assertIn("[earlier](Current/Record.md)", payload["changes"]["reader.md"])
        for name, raw in before.items():
            self.assertEqual(payload["files"][name], hashlib.sha256(raw).hexdigest())
            self.assertEqual((self.root / name).read_bytes(), raw)
        for name, raw in payload["originals"].items():
            self.assertEqual(base64.b64decode(raw), before[name])
        self.assertFalse((self.root / ".git").exists())

    def test_mixed_workspace_skips_links_binaries_and_literal_exclusions(self):
        self.write(".planisphere/scope.json", json.dumps({"excludedPaths": ["generated (copy)/"]}))
        self.write("generated (copy)/Record.md", "# Excluded\n")
        self.write("generated (copy)/broken.md", "# Excluded\n")
        self.write("attachment.bin", "unchanged attachment")
        (self.root / "external.md").symlink_to(self.base / "missing")
        os.mkfifo(self.root / "pipe.md")
        packet = self.prepare()
        self.assertEqual(packet["packet"]["scope"]["excludedPaths"], ["generated (copy)/"])
        self.assertEqual(len(packet["packet"]["files"]), 4)
        self.write("attachment.bin", "new excluded bytes")
        self.assertEqual(self.verify(packet), packet)

    def test_changed_notes_and_settings_invalidate_review(self):
        packet = self.prepare()
        self.write("reader.md", "new concurrent text")
        with self.assertRaisesRegex(ValueError, "changed since scanning"):
            self.verify(packet)
        packet = self.prepare()
        self.write(".planisphere/scope.json", "{}")
        with self.assertRaisesRegex(ValueError, "changed since scanning"):
            self.verify(packet)

    def test_tampered_changes_or_digest_refused(self):
        packet = self.prepare()
        packet["packet"]["changes"]["reader.md"] = "unreviewed edit"
        packet["digest"] = B.digest(packet["packet"])
        with self.assertRaisesRegex(ValueError, "modified or are stale"):
            self.verify(packet)
        packet = self.prepare()
        packet["digest"] = "0" * 64
        with self.assertRaisesRegex(ValueError, "modified or are stale"):
            self.verify(packet)

    def test_complete_current_candidate_group_is_required(self):
        self.write("Other/Record.md", "# Other\n[[evidence]]\n")
        with self.assertRaisesRegex(ValueError, "complete current candidate group"):
            self.prepare()
        with self.assertRaises(ValueError):
            self.prepare(members=self.members + [self.members[0]])
        with self.assertRaises(ValueError):
            self.prepare(keep="evidence.md")
        with self.assertRaises(ValueError):
            self.prepare(members=self.members + ["evidence.md"])

    def test_new_candidate_invalidates_scan(self):
        fingerprint = self.scan()["fingerprint"]
        self.write("Other/Record.md", "# Added later\n")
        with self.assertRaisesRegex(ValueError, "changed since scanning"):
            self.prepare(fingerprint=fingerprint)

    def test_unique_evidence_affect_anchor_and_code_guards(self):
        variants = [
            ("Archive/Record.md", "# Earlier\n[[evidence]]\nhttps://example.org/unique", "unique evidence"),
            ("Archive/Record.md", "---\naffect_hold: true\n---\n# Earlier\n[[evidence]]\n", "affect hold"),
            ("reader.md", "[[Archive/Record#section]]", "anchored reference"),
            ("reader.md", "Example: `[[Archive/Record]]`", "Code examples"),
        ]
        for name, text, error in variants:
            original = (self.root / name).read_text()
            self.write(name, text)
            with self.subTest(error=error), self.assertRaisesRegex(ValueError, error):
                self.prepare()
            self.write(name, original)

    def test_canvas_is_held_even_though_not_checkpointed(self):
        self.write("diagram.canvas", '{"nodes":[]}')
        with self.assertRaisesRegex(ValueError, "Canvas links"):
            self.prepare()

    def test_attachment_references_are_preserved_without_reading_attachments(self):
        self.write("Archive/Record.md", "# Earlier\n[[evidence]]\n![diagram](../assets/plot.png)\n")
        with self.assertRaisesRegex(ValueError, "Unique attachment references"):
            self.prepare()
        self.write("Current/Record.md", "# Current\n[[evidence]]\n![same diagram](../assets/plot.png)\n")
        self.assertIn("Archive/Record.md", self.prepare()["packet"]["changes"])
        # Identical spelling in different folders names different attachments.
        self.write("Archive/Record.md", "# Earlier\n[[evidence]]\n![diagram](plot.png)\n")
        self.write("Current/Record.md", "# Current\n[[evidence]]\n![diagram](plot.png)\n")
        with self.assertRaisesRegex(ValueError, "Unique attachment references"):
            self.prepare()

    def test_unrelated_links_do_not_hold_every_local_review(self):
        self.write("navigation.md", "[Workspace](/Users/logan/planisphere-build)\n[external][guide]\n[guide]: https://example.org/guide\n<A HREF=\"https://example.org\">External</A>\n")
        packet = self.prepare()
        self.assertNotIn("navigation.md", packet["packet"]["changes"])
        self.assertEqual(self.verify(packet), packet)

    def test_supported_backlink_updates_preserve_unrelated_rich_links_in_same_note(self):
        text = '[old](Archive/Record.md)\n[guide][web]\n[web]: https://example.org/guide\n<A HREF="https://example.org">External</A>\n'
        self.write("reader.md", text)
        packet = self.prepare()
        self.assertEqual(packet["packet"]["changes"]["reader.md"], text.replace("Archive/Record.md", "Current/Record.md"))

    def test_unsupported_incoming_links_to_retiring_note_still_hold(self):
        variants = [
            '[prior](Archive/Record.md "title")',
            '[prior](<Archive/Record.md>)',
            '<A HREF="Archive/Record.md">prior</A>',
            '[prior][old]\n[old]: Archive/Record.md',
            '[prior](' + str(self.root / 'Archive/Record.md') + ')',
        ]
        for text in variants:
            self.write("reader.md", text)
            with self.subTest(text=text), self.assertRaises(ValueError):
                self.prepare()

    def test_cli_policy_cannot_silently_fall_back_to_local(self):
        output = io.StringIO()
        with redirect_stdout(output):
            code = B.main(["prepare-local", "--engine-root", str(ENGINE), "--vault", str(self.root),
                           "--policy", str(self.base / "policy.json"), "--members", json.dumps(self.members),
                           "--keep", self.members[0], "--fingerprint", self.scan()["fingerprint"]])
        self.assertEqual(code, 2)
        self.assertIn("cannot be bypassed", json.loads(output.getvalue())["error"])


if __name__ == "__main__":
    unittest.main()
