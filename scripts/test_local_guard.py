#!/usr/bin/env python3
"""Pure-input regressions for local pruning parser and attachment boundaries."""
from pathlib import Path
import importlib.util
import sys
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
PROJECT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("planisphere_local_guard", PROJECT / "Integrations/Grapheine/local_guard.py")
G = importlib.util.module_from_spec(spec)
spec.loader.exec_module(G)


class LocalGuardTests(unittest.TestCase):
    def validate(self, text):
        G.validate_local_markdown({"reader.md": text}, Path("/does/not/exist"))

    def test_normal_notes_attachments_quotes_and_code_are_supported(self):
        self.validate('''---
canonical_owner: "Archive/Record.md"
---
# Ordinary note
She said "keep the source".
[[Archive/Record|source]] and [source](Archive/Record.md).
![plot](assets/plot.png) and [paper](paper.pdf#page=4).
[site](https://example.test/a.md "External title") and <em>emphasis</em>.
`[example](<Archive/Record.md>)`
```markdown
<A HREF="Archive/Record.md">example</A>
```
    [example](Archive/Record.md "title")
''')

    def test_unsupported_note_link_shapes_are_held(self):
        for text in ['[old](Archive/Record.md "title")', '[old](<Archive/Record.md>)',
                     '![old](Archive/Record.md "title")', '[old](Archive/Record.md?view=1)',
                     '[old](Archive/Record.MD)', '[old](Archive/Record.markdown)',
                     '[old](Archive/Record%2Emd)',
                     '[old](Archive/(Record).md)', '[old](Archive\\ Record.md)',
                     '[old [nested]](Archive/Record.md)', '[old](\nArchive/Record.md\n)',
                     '[old](Archive/Record.md']:
            with self.subTest(text=text), self.assertRaisesRegex(ValueError, "reader.md"):
                self.validate(text)

    def test_html_and_reference_links_are_held_case_insensitively(self):
        for text in ['<A HREF="Archive/Record.md">old</A>', '<IFRAME src="Record.md"></IFRAME>',
                     '<IMG SRC="plot.png">', '<custom href="Record.md">', '[old]: Archive/Record.md']:
            with self.subTest(text=text), self.assertRaises(ValueError):
                self.validate(text)

    def test_absolute_wiki_and_owner_paths_are_held_without_probing(self):
        examples = ['[old](/Users/logan/vault/Record.md)', '[old](%2FUsers%2Flogan%2Fvault%2FRecord.md)',
                    '[old](file:///Users/logan/vault/Record.md)', '[old](obsidian://open?vault=x&file=y)',
                    '[[/Users/logan/vault/Record]]', '[[../Record]]',
                    '---\ncanonical_owner: "/Users/logan/vault/Record.md"\n---\n',
                    '---\ncanonical_owner: ../Record.md\n---\n']
        with patch.object(Path, "resolve", side_effect=AssertionError("No filesystem probes")), patch.object(Path, "read_text", side_effect=AssertionError("No reads")):
            for text in examples:
                with self.subTest(text=text), self.assertRaises(ValueError):
                    self.validate(text)

    def test_attachments_are_normalized_relative_to_each_source(self):
        a = G.local_attachment_references('![plot](../assets/plot%20one.png#view) [paper](paper.pdf)', 'Archive/Record.md')
        b = G.local_attachment_references('![plot](assets/plot%20one.png#view) [paper](paper.pdf)', 'Record.md')
        self.assertIn('local:["assets/plot one.png","view"]', a & b)
        self.assertIn('local:["Archive/paper.pdf",null]', a)
        self.assertIn('local:["paper.pdf",null]', b)
        self.assertNotEqual(a, b)
        self.assertNotEqual(G.local_attachment_references('[x](plot%23crop.png)'), G.local_attachment_references('[x](plot#crop.png)'))

    def test_attachment_footprint_preserves_urls_and_ignores_code_and_note_refs(self):
        result = G.local_attachment_references('[note](Record.md#heading) [web](https://example.test/a "title") `![example](not-real.png)`')
        self.assertEqual(result, {'url:https://example.test/a "title"'})
        self.assertEqual(G.local_attachment_references('[relative](../../outside.pdf)', 'nested/Record.md'), {'local:["../outside.pdf",null]'})

    def targeted(self, incoming, family_text="Same reviewed content.", aliases=None):
        G.validate_local_markdown({"Record.md": family_text, "Archive/Record.md": "Same reviewed content.", "BUILD-ZONE.md": incoming},
                                  Path("/Users/logan/vault"), members=["Record.md", "Archive/Record.md"],
                                  retired={"Archive/Record.md"}, retired_aliases=aliases or [])

    def test_unrelated_absolute_docs_web_definitions_and_html_do_not_hold(self):
        self.targeted('''[workspace](/Users/logan/other-project/docs)
[other](file:///Users/logan/other-project/Unrelated.md)
[other](Other.md "title")
[site]: https://example.test/Record.md
<A HREF="https://example.test/Record.md">website</A>
<IMG src="assets/unrelated.png">
---
canonical_owner: /Users/logan/other-project/Unrelated.md
---
''')

    def test_unsupported_incoming_destinations_and_aliases_hold(self):
        cases = ['[old](/Users/logan/vault/Archive/Record.md)',
                 '[old](file:///Users/logan/vault/Archive/Record.md)',
                 '[old](obsidian://open?vault=Vault&file=Archive%2FRecord)',
                 '[old](Archive/Record.md "title")', '[old](<Archive/Record.md>)',
                 '[old](Archive/Record%2Emd)', '[old](Archive/Record.md',
                 '[old]: Archive/Record.md "title"', '<A HREF="Archive/Record.md">old</A>',
                 '<A HREF="Archive/Record.md"', '<a href="Archive&#47;Record.md">old</a>',
                 '[[../Archive/Record]]', '---\ncanonical_owner: /Users/logan/vault/Archive/Record.md\n---\n',
                 '[old](<Old Decision>)', '<A HREF="Old%20Decision">old</A>']
        for text in cases:
            with self.subTest(text=text), self.assertRaisesRegex(ValueError, 'BUILD-ZONE.md'):
                self.targeted(text, aliases=['Old Decision'])

    def test_selected_family_keeps_strict_outgoing_evidence_checks(self):
        for text in ['[unrelated](/Users/logan/other-project/docs)', '[web]: https://example.test', '<img src="other.png">']:
            with self.subTest(text=text), self.assertRaisesRegex(ValueError, 'Record.md'):
                self.targeted('Ordinary unrelated note.', family_text=text)

    def test_unknown_dynamic_references_hold_but_supported_incoming_links_pass(self):
        self.targeted('[[Archive/Record]] [old](Archive/Record.md) [elsewhere](other.pdf)')
        for text in ['<a href="${destination}">unknown</a>', '[link]:', '[x](obsidian://open?vault=Vault)']:
            with self.subTest(text=text), self.assertRaises(ValueError):
                self.targeted(text)


if __name__ == "__main__":
    unittest.main()
