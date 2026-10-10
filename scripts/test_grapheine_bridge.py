#!/usr/bin/env python3
"""Disposable-fixture acceptance checks for the native Grapheine bridge.

Run: python3 -B scripts/test_grapheine_bridge.py [--engine-root /path/to/Grapheine]
The cryptography dependency is required for signed-authority fixture tests.
"""
from __future__ import annotations
import argparse
import base64
from datetime import datetime, timedelta, timezone
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from unittest.mock import patch

sys.dont_write_bytecode = True
PROJECT = Path(__file__).resolve().parents[1]
SCRIPT = PROJECT / "Integrations/Grapheine/bridge.py"
parser = argparse.ArgumentParser(add_help=False)
parser.add_argument("--engine-root", type=Path, default=PROJECT.parent / "Grapheine")
known, remaining = parser.parse_known_args()
ENGINE = known.engine_root.resolve()
spec = importlib.util.spec_from_file_location("native_grapheine_bridge", SCRIPT)
B = importlib.util.module_from_spec(spec)
spec.loader.exec_module(B)
try:
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
    HAS_CRYPTO = True
except ImportError:
    HAS_CRYPTO = False


class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="planisphere-grapheine-", dir="/private/tmp")
        self.base = Path(self.temp.name)
        self.root = self.base / "Vault 'quoted'; $(not a command)"
        self.root.mkdir()
        self.G, self.A = B.load_engine(ENGINE)

    def tearDown(self):
        self.temp.cleanup()

    def write(self, path, content):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")

    def invoke(self, action, *extra):
        stream = io.StringIO()
        with redirect_stdout(stream):
            code = B.main([action, "--engine-root", str(ENGINE), "--vault", str(self.root), *extra])
        return code, json.loads(stream.getvalue())

    def setup_authority(self, *, git=True, held=False):
        if not HAS_CRYPTO:
            self.skipTest("cryptography needed for disposable signed-authority fixtures")
        self.write(self.root / "a.md", "# Current\n[[evidence]]\n")
        self.write(self.root / "b.md", ("---\naffect_hold: true\n---\n" if held else "") + "# Prior\n[[evidence]]\n")
        self.write(self.root / "evidence.md", "# Evidence\n")
        self.write(self.root / "reader.md", "Read [[b|prior]] or [prior](b.md).\n")
        self.policy = self.base / "policy.json"
        self.manifest = self.base / "questions.json"
        self.store = self.base / "authority.jsonl"
        self.key = Ed25519PrivateKey.generate()
        self.question = {"id": "q", "scope": "project", "values": ["a.md", "b.md"], "candidates": ["a.md", "b.md"]}
        self.write(self.manifest, json.dumps({"questions": [self.question]}))
        self.write(self.policy, json.dumps({"schema": self.A.DOMAIN, "vault": str(self.root),
            "manifest": str(self.manifest), "store": str(self.store), "principals": {
                "fixture-only": {"public_key": self.key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw).hex(),
                                 "scopes": ["project"], "permissions": ["authority", "settlement"]}}}))
        if git:
            self.A.git(self.root, "init")
            self.A.git(self.root, "config", "user.name", "Fixture")
            self.A.git(self.root, "config", "user.email", "fixture@example.invalid")
            self.commit()
        with B.policy_environment(self.policy, self.root):
            self.A.append_record(self.seal({**self.common(), "id": "decision-1", "kind": "decision", "scope": "project", "question": "q", "value": "a.md", "question_digest": self.A.digest(self.question), "evidence": {name: self.A.file_hash(self.root / name) for name in self.question["candidates"]}}), self.A.policy_context())

    def commit(self):
        self.A.git(self.root, "add", ".")
        self.A.git(self.root, "commit", "--allow-empty", "-m", "Disposable fixture")

    def common(self):
        now = datetime.now(timezone.utc)
        return {"domain": self.A.DOMAIN, "vault": str(self.root), "author": "test-agent", "approver": "fixture-only", "created_at": (now - timedelta(minutes=2)).isoformat(), "expires_at": (now + timedelta(hours=2)).isoformat(), "statement": "Disposable test fixture only"}

    def seal(self, record):
        return {"record": record, "signature": base64.b64encode(self.key.sign(self.A.canonical(record))).decode()}

    def prepare(self):
        return self.invoke("prepare", "--policy", str(self.policy), "--scope", "project", "--question", "q")

    def save_permission(self, packet, *, digest=None):
        packet_path, receipt_path = self.base / "packet.json", self.base / "permission.json"
        self.write(packet_path, json.dumps(packet))
        self.write(receipt_path, json.dumps(self.seal({**self.common(), "kind": "settlement", "scopes": ["project"], "packet_digest": digest or packet["digest"]})))
        return packet_path, receipt_path

    def apply(self, packet_path, receipt_path):
        return self.invoke("apply", "--policy", str(self.policy), "--packet", str(packet_path), "--receipt", str(receipt_path))

    def test_scan_is_real_read_only_and_contract_handles_odd_paths(self):
        self.write(self.root / "Sales/Status.md", "# Sales\n[[shared]]")
        self.write(self.root / "Hiring/Status.md", "# Hiring\n[[shared]]")
        self.write(self.root / "shared.md", "# Shared")
        self.write(self.root / ".planisphere/scope.json", "{}")
        (self.root / "attachment.bin").write_bytes(bytes([0, 42, 255]))
        before = B.snapshot(self.root)
        code, result = self.invoke("scan")
        self.assertEqual(code, 0, result)
        self.assertEqual(result["notes"], 3)
        self.assertEqual(result["totalGroups"], 1)
        self.assertEqual(set(result["groups"][0]["members"]), {"Sales/Status.md", "Hiring/Status.md"})
        self.assertEqual(result["authority"]["status"], "notConfigured")
        self.assertEqual(before, B.snapshot(self.root))
        self.assertFalse((self.root / ".git").exists())
        self.assertFalse(list(self.root.rglob("__pycache__")))
        process = subprocess.run([sys.executable, "-B", str(SCRIPT), "scan", "--engine-root", str(ENGINE), "--vault", str(self.root)], input="ignored input, not a command", text=True, capture_output=True)
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(json.loads(process.stdout)["fingerprint"], result["fingerprint"])

    def test_unavailable_policy_preserves_scan(self):
        self.write(self.root / "note.md", "# Note")
        code, result = self.invoke("scan", "--policy", str(self.base / "missing.json"))
        self.assertEqual(code, 0)
        self.assertEqual(result["notes"], 1)
        self.assertEqual(result["authority"]["status"], "unavailable")

    def test_wrong_policy_vault_refuses_prepare_but_preserves_scan(self):
        self.setup_authority()
        other = self.base / "Other"; other.mkdir()
        raw = json.loads(self.policy.read_text()); raw["vault"] = str(other)
        self.write(self.policy, json.dumps(raw))
        code, scan = self.invoke("scan", "--policy", str(self.policy))
        self.assertEqual(code, 0)
        self.assertEqual(scan["authority"]["status"], "unavailable")
        code, result = self.prepare()
        self.assertNotEqual(code, 0)
        self.assertIn("different vault", result["error"])

    def test_non_git_prepare_is_explicitly_held_without_creating_git(self):
        self.setup_authority(git=False)
        before = B.snapshot(self.root)
        code, result = self.prepare()
        self.assertNotEqual(code, 0)
        self.assertIn("git", result["error"].lower())
        self.assertFalse((self.root / ".git").exists())
        self.assertEqual(before, B.snapshot(self.root))

    def test_exact_signed_apply_commits_existing_engine_result(self):
        self.setup_authority()
        old = self.A.git(self.root, "rev-parse", "HEAD")
        before_index = (self.root / ".git/index").read_bytes()
        code, packet = self.prepare()
        self.assertEqual(code, 0, packet)
        self.assertEqual(before_index, (self.root / ".git/index").read_bytes())
        paths = self.save_permission(packet)
        code, result = self.apply(*paths)
        self.assertEqual(code, 0, result)
        self.assertEqual(result["commit"], self.A.git(self.root, "rev-parse", "HEAD"))
        self.assertEqual(old, self.A.git(self.root, "rev-parse", "HEAD^"))
        self.assertFalse((self.root / "b.md").exists())
        self.assertIn("[[a|prior]]", (self.root / "reader.md").read_text())
        self.assertEqual(self.A.git(self.root, "status", "--porcelain"), "")
        code, scan = self.invoke("scan", "--policy", str(self.policy))
        self.assertEqual(code, 0, scan)
        self.assertEqual(scan["authority"]["questions"][0]["state"], "resolved")

    def test_stale_attachment_refuses_apply_without_touching_notes(self):
        self.setup_authority()
        code, packet = self.prepare(); self.assertEqual(code, 0, packet)
        paths = self.save_permission(packet)
        self.write(self.root / "attachment.bin", "new attachment")
        before = B.snapshot(self.root)
        code, result = self.apply(*paths)
        self.assertNotEqual(code, 0)
        self.assertEqual(before, B.snapshot(self.root))
        self.assertTrue((self.root / "b.md").exists())

    def test_wrong_exact_permission_refuses_apply(self):
        self.setup_authority()
        code, packet = self.prepare(); self.assertEqual(code, 0, packet)
        paths = self.save_permission(packet, digest="0" * 64)
        before = B.snapshot(self.root)
        code, result = self.apply(*paths)
        self.assertNotEqual(code, 0)
        self.assertIn("G2", result["error"])
        self.assertEqual(before, B.snapshot(self.root))

    def test_affect_hold_is_preserved(self):
        self.setup_authority(held=True)
        before = B.snapshot(self.root)
        code, result = self.prepare()
        self.assertNotEqual(code, 0)
        self.assertIn("G4", result["error"])
        self.assertEqual(before, B.snapshot(self.root))

    def test_preservation_hold_is_preserved(self):
        self.setup_authority()
        self.write(self.root / "reader.md", "See [[b#important]].\n")
        self.commit()
        code, result = self.prepare()
        self.assertNotEqual(code, 0)
        self.assertIn("G5", result["error"])

    def test_inline_fenced_and_escaped_code_holds_prepare_and_imported_apply(self):
        self.setup_authority()
        for example in ["Example `[[b]]`.\n", "```markdown\n[[b]]\n```\n", "Example \\[[b]].\n", "~~~markdown\n[[b]]\n~~~\n", "    Example [[b]].\n", "Example \\[prior](b.md).\n"]:
            self.write(self.root / "reader.md", example)
            self.commit()
            before = B.snapshot(self.root)
            code, result = self.prepare()
            self.assertNotEqual(code, 0, example)
            self.assertIn("Code examples would change", result["error"])
            # A packet from the unmodified engine cannot bypass the adapter hold.
            with B.policy_environment(self.policy, self.root):
                packet = self.A.build_packet(self.A.policy_context(), "project", "q")
            paths = self.save_permission(packet)
            code, result = self.apply(*paths)
            self.assertNotEqual(code, 0, result)
            self.assertIn("Code examples would change", result["error"])
            self.assertEqual(before, B.snapshot(self.root))

    def test_discovery_excludes_links_and_special_files_but_root_link_is_rejected(self):
        self.write(self.root / "note.md", "# Note")
        (self.root / "link").symlink_to(self.base)
        os.mkfifo(str(self.root / "pipe"))
        code, result = self.invoke("scan")
        self.assertEqual(code, 0, result)
        self.assertEqual(result["notes"], 1)
        self.assertIn("link", result["scope"]["excludedPaths"])
        self.assertIn("pipe", result["scope"]["excludedPaths"])
        with self.assertRaisesRegex(B.BridgeError, "Symbolic links and special"):
            B.snapshot(self.root)
        alias = self.base / "alias"; alias.symlink_to(self.root)
        stream = io.StringIO()
        with redirect_stdout(stream):
            code = B.main(["scan", "--engine-root", str(ENGINE), "--vault", str(alias)])
        self.assertNotEqual(code, 0)

    def test_explicit_obsidian_and_hidden_checkout_exclusions(self):
        self.write(self.root / "Status.md", "# Main")
        self.write(self.root / "Archive/Status.md", "# Archive")
        self.write(self.root / "Ignored/Status.md", "# Excluded")
        self.write(self.root / "Ignored file.md", "# Excluded file")
        self.write(self.root / "node_modules/Status.md", "# Dependency")
        self.write(self.root / ".hidden-checkout/Status.md", "# Hidden checkout")
        (self.root / ".hidden-checkout/core").symlink_to(self.base / "missing")
        self.write(self.root / ".planisphere/scope.json", json.dumps({"excludedPaths": ["Ignored/", "Ignored file.md"]}))
        code, result = self.invoke("scan")
        self.assertEqual(code, 0, result)
        self.assertEqual(result["notes"], 2)
        self.assertEqual(set(result["groups"][0]["members"]), {"Status.md", "Archive/Status.md"})
        scope = result["scope"]
        self.assertEqual(scope["kind"], "markdown-discovery")
        self.assertIn("Ignored/", scope["appliedFilters"])
        for name in ["Ignored/", "Ignored file.md", "node_modules/", ".hidden-checkout/"]:
            self.assertIn(name, scope["excludedPaths"])
        self.assertEqual(result["vaultPath"], str(self.root))

    def test_excluded_and_outside_targets_are_never_read_or_probed(self):
        forbidden = self.base / "Private outside"; forbidden.mkdir()
        self.write(forbidden / "Secret.md", "not discovery evidence")
        self.write(self.root / "Included.md", "---\ncanonical_owner: " + str(forbidden / "Secret.md") + "\n---\n[secret](" + str(forbidden / "Secret.md") + ")")
        self.write(self.root / "Excluded/Secret.md", "not discovery evidence")
        self.write(self.root / ".planisphere/scope.json", json.dumps({"excludedPaths": ["Excluded/"]}))
        (self.root / "linked.md").symlink_to(forbidden / "Secret.md")
        original_stat, original_read = Path.stat, Path.read_text
        def checked_stat(path, *args, **kwargs):
            if str(path).startswith(str(forbidden)):
                raise AssertionError("Outside discovery target was probed")
            return original_stat(path, *args, **kwargs)
        def checked_read(path, *args, **kwargs):
            if str(path).startswith(str(forbidden)) or path == self.root / "Excluded/Secret.md":
                raise AssertionError("Excluded note was read")
            return original_read(path, *args, **kwargs)
        with patch.object(Path, "stat", checked_stat), patch.object(Path, "read_text", checked_read):
            result = B.scan(self.G, self.A, self.root)
        self.assertEqual(result["notes"], 1)
        self.assertIn("linked.md", result["scope"]["excludedPaths"])

    def test_binary_contents_are_not_read_and_changes_do_not_invalidate_discovery(self):
        self.write(self.root / "note.md", "# Note")
        binary = self.root / "attachment.bin"
        binary.write_bytes(b"binary contents")
        identity = binary.stat().st_ino
        original_read, original_accounts = os.read, self.G._accounts_payload
        def checked_read(descriptor, size):
            if os.fstat(descriptor).st_ino == identity:
                raise AssertionError("Binary contents were read by discovery")
            return original_read(descriptor, size)
        def changing_binary(*args, **kwargs):
            result = original_accounts(*args, **kwargs)
            binary.write_bytes(b"changed binary contents")
            return result
        with patch("os.read", side_effect=checked_read), patch.object(self.G, "_accounts_payload", side_effect=changing_binary):
            result = B.scan(self.G, self.A, self.root)
        self.assertEqual(result["notes"], 1)

    def test_original_absolute_owner_maps_only_to_included_note(self):
        self.write(self.root / "Answer.md", "# Kept")
        self.write(self.root / "Copy.md", "---\ncanonical_owner: " + str(self.root / "Answer.md") + "\n---\n# Copy")
        result = B.scan(self.G, self.A, self.root)
        self.assertEqual(result["totalGroups"], 1)
        self.assertEqual(result["groups"][0]["declaredCopies"], 1)
        self.assertEqual(set(result["groups"][0]["members"]), {"Answer.md", "Copy.md"})
        self.assertIn("canonical_owner", (self.root / "Copy.md").read_text())

    def test_scope_is_bounded_and_unsupported_rules_are_explicit(self):
        self.write(self.root / "Keep.md", "# Keep")
        for number in range(105):
            self.write(self.root / ("binary-%03d.bin" % number), "binary")
        self.write(self.root / ".planisphere/scope.json", json.dumps({"excludedPaths": ["*.md", "/regex/", "../outside", 7]}))
        result = B.scan(self.G, self.A, self.root)
        scope = result["scope"]
        self.assertEqual(result["notes"], 1)
        self.assertEqual(len(scope["excludedPaths"]), 100)
        self.assertGreater(scope["excludedCount"], 100)
        self.assertTrue(scope["truncated"])
        self.assertEqual(len(scope["unsupportedFilters"]), 4)
        self.assertFalse(scope["appliedFilters"])

    def test_exclusion_change_during_scan_invalidates_result(self):
        self.write(self.root / "note.md", "# Note")
        self.write(self.root / ".planisphere/scope.json", "{}")
        original = self.G._accounts_payload
        def changing_rules(*args, **kwargs):
            result = original(*args, **kwargs)
            self.write(self.root / ".planisphere/scope.json", json.dumps({"excludedPaths": ["note.md"]}))
            return result
        with patch.object(self.G, "_accounts_payload", side_effect=changing_rules):
            with self.assertRaisesRegex(B.BridgeError, "scope changed while scanning"):
                B.scan(self.G, self.A, self.root)

    def test_discovery_exclusions_do_not_weaken_authority_or_preparation(self):
        self.setup_authority()
        self.write(self.root / ".hidden-checkout/README.md", "not a note")
        (self.root / ".hidden-checkout/core").symlink_to(self.base / "missing")
        code, result = self.invoke("scan", "--policy", str(self.policy))
        self.assertEqual(code, 0, result)
        self.assertEqual(result["notes"], 4)
        self.assertEqual(result["authority"]["status"], "unavailable")
        self.assertIn("Symbolic links and special", result["authority"]["message"])
        code, result = self.prepare()
        self.assertNotEqual(code, 0)
        self.assertIn("Symbolic links and special", result["error"])

    def test_excluded_invalid_markdown_is_not_opened(self):
        self.write(self.root / "Good.md", "# Good")
        self.write(self.root / ".planisphere/scope.json", json.dumps({"excludedPaths": ["Excluded/"]}))
        self.write(self.root / "Excluded/Bad.md", "placeholder")
        (self.root / "Excluded/Bad.md").write_bytes(b"bad \xff")
        code, result = self.invoke("scan")
        self.assertEqual(code, 0, result)
        self.assertEqual(result["notes"], 1)

    def test_unreadable_exclusion_config_does_not_silently_ignore_rules(self):
        self.write(self.root / "Good.md", "# Good")
        self.write(self.root / ".planisphere/scope.json", "not JSON")
        code, result = self.invoke("scan")
        self.assertNotEqual(code, 0)
        self.assertIn("exclusion settings", result["error"])

    def test_changed_scan_is_not_published(self):
        self.write(self.root / "note.md", "old")
        original = self.G._accounts_payload
        def changing(*args, **kwargs):
            result = original(*args, **kwargs)
            self.write(self.root / "note.md", "new")
            return result
        with patch.object(self.G, "_accounts_payload", side_effect=changing):
            with self.assertRaisesRegex(B.BridgeError, "changed while scanning"):
                B.scan(self.G, self.A, self.root)

    def test_missing_crypto_keeps_candidate_scan(self):
        self.setup_authority()
        process = subprocess.run([sys.executable, "-S", "-B", str(SCRIPT), "scan", "--engine-root", str(ENGINE), "--vault", str(self.root), "--policy", str(self.policy)], text=True, capture_output=True)
        self.assertEqual(process.returncode, 0, process.stderr)
        result = json.loads(process.stdout)
        self.assertEqual(result["notes"], 4)
        self.assertEqual(result["authority"]["status"], "unavailable")
        self.assertIn("cryptography", result["authority"]["message"])

    def test_invalid_utf8_markdown_blocks_scan(self):
        (self.root / "invalid.md").write_bytes(b"# Bad UTF-8 \xff")
        code, result = self.invoke("scan")
        self.assertNotEqual(code, 0)
        self.assertIn("valid UTF-8", result["error"])

    def test_completed_commit_index_failure_returns_verified_warning(self):
        self.setup_authority()
        code, packet = self.prepare(); self.assertEqual(code, 0, packet)
        paths = self.save_permission(packet)
        previous = self.A.git(self.root, "rev-parse", "HEAD")
        original_replace = os.replace
        def failing_index_replace(source, destination, *args, **kwargs):
            if Path(destination) == self.root / ".git/index":
                raise OSError("injected index refresh failure")
            return original_replace(source, destination, *args, **kwargs)
        with patch("os.replace", side_effect=failing_index_replace):
            code, result = self.apply(*paths)
        self.assertEqual(code, 0, result)
        self.assertEqual(result["commit"], self.A.git(self.root, "rev-parse", "HEAD"))
        self.assertNotEqual(result["commit"], previous)
        self.assertIn("index could not be refreshed", result["message"])
        self.assertFalse((self.root / "b.md").exists())
        code, repeated = self.apply(*paths)
        self.assertNotEqual(code, 0, repeated)
        self.assertEqual(result["commit"], self.A.git(self.root, "rev-parse", "HEAD"))

    def test_engine_tampering_fails_closed(self):
        engine = self.base / "tampered"; engine.mkdir()
        for name in B.ENGINE_HASHES:
            (engine / name).write_bytes((ENGINE / name).read_bytes())
        with (engine / "grapheine.py").open("ab") as file:
            file.write(b"\n# alteration")
        with self.assertRaisesRegex(B.BridgeError, "Unsupported Grapheine source"):
            B.load_engine(engine)


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0], *remaining], verbosity=2)
