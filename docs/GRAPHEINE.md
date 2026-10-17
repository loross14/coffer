# Grapheine integration, 0.4.0

Planisphere for Mac uses Grapheine for candidate discovery and preservation checks. Its default local review applies through native Markdown checkpoints, without Git, a signing service or an account. An existing signed authority policy selects a separate legacy workflow. Neither mode uploads vault contents.

## Local review and native recovery

1. Scan an ordinary vault. Select a candidate group, read its members, and explicitly choose the note to keep. No keeper is selected automatically.
2. Review Changes rechecks the scan fingerprint and complete candidate membership. A private Markdown copy feeds the pinned Grapheine planner; the original vault remains untouched. The proposal pins every included note, all supported literal exclusions and the settings hash. A truncated group cannot be treated as a complete group.
3. Inspect exact original and replacement text for every retired note and backlink rewrite. The retained account is a human choice, not a consequence of a graph score. Supported-reference preservation, affect holds and code-example protection still apply. Unsupported links in the selected family, unsupported incoming references that may target retiring notes, and nonexcluded canvas files hold the proposal. Unrelated documentation links do not block every review. Attachment references must remain represented by the keeper, although attachment bytes are not captured.
4. Apply Reviewed Changes requires explicit confirmation of the displayed plan. The bridge recomputes that same plan without Git. The native store then checks the complete Markdown inventory and scope again, saves a pre-change checkpoint, and durably records the plan and pending receipt before changing any note.
5. The store preserves each displaced original inode in a hidden same-folder recovery file and applies only the reviewed bytes. It verifies the complete expected result, publishes an after checkpoint, and marks the receipt completed. Checkpoints, journal and recovery files remain local.

This is a **local manual review**, not an externally signed G1/G2 authority decision or a cryptographically authenticated human identity. It does not provision keys, append decisions to an authority log, or pretend that a click satisfies a separately configured signed policy. When a policy is selected, the app uses signed mode; it never silently falls back to local consent after a failed signed check.

Local scope is the same Markdown Only scope used by native checkpoints: regular lowercase `.md` files outside hidden/dependency folders and supported literal Planisphere exclusions. Attachments, settings, symbolic links, excluded notes and other vaults are outside the saved content scope. Incoming references from excluded content and external applications are not checked or rewritten. Keeping a note does not prove that every meaning in retired prose survives; the user must assess that in review.

The pre-change checkpoint enables **Restore Copy**, which creates a separate recovered vault without overwriting current work. The store's `vaults/<id>/mutations/<operation-id>.json` journal records exact reviewed bytes, checkpoint IDs, changed paths, retained recovery paths and completion state. Local metadata checksums detect corruption; they are not signatures. A pending operation found after restart becomes interrupted and is never automatically replayed. The UI surfaces the recovery checkpoint and retained paths. After inspecting recovery, explicit acknowledgment permits a fresh review; it does not mark the old operation completed or replay it. An interrupted staging path may contain an unexchanged replacement, so inspect it against the journal and precheckpoint. No automatic cleanup deletes retained originals.

Close editors and sync while applying. Multi-file changes cannot be atomic against arbitrary external writers. Descriptor-relative traversal rejects symlink parents; atomic swaps/exclusive renames retain the actual displaced inode, including late writes by an editor holding it open. Detected concurrent changes stop the operation and preserve recovery evidence; no blind rollback overwrites those changes. A stopped operation may be partly applied, and the UI reports that uncertainty. Checkpoint restore/export recovers captured Markdown, not later edits held only in the retained recovery files.

## Optional legacy signed-policy flow

### Review and apply

1. Select a vault and open Pruning. Scan Vault reads its current files; it does not create a checkpoint or change notes.
2. Inspect candidate groups, member text and Grapheine's guidance. The displayed group count distinguishes all nominated groups from the bounded displayed list. Current note previews can change after a scan; the exact operation preview is separately pinned.
3. Optionally connect an existing external authority policy for this exact vault. The app reads declared questions and signed decisions. It never writes the policy, creates a signer, or treats candidate ranking as approval.
4. For a resolved eligible question, prepare the exact changes. The underlying packet pins all included file contents, policy, question manifest, authority log and Git HEAD. Review every retirement and rewritten link; export the packet for the independently controlled signer.
5. Load the signed permission for this exact packet and choose Apply Reviewed Changes. Planisphere captures current working bytes in a checkpoint before invoking the existing apply path. Grapheine re-derives the packet, verifies signatures, freshness, affect holds and evidence preservation, and creates a local Git commit with its signed audit. Planisphere captures a second checkpoint after successful completion.

This separate signed contract requires a clean Git vault. No remote or GitHub storage is required. These requirements belong to legacy signed mode; the local review flow above uses native checkpoints.

### Signed-mode boundaries and recovery

- Before apply, close editing and sync writers. Grapheine's locks coordinate itself and Git, not arbitrary editors. Multi-file application cannot be atomic against a noncooperating editor. A crash can leave partial working changes and stale locks; inspect the local Git receipt and use the saved pre-operation checkpoint to restore a new folder.
- Discovery inventories included Markdown before/after and refuses changed included notes or scope. It skips hidden/dependency folders, non-Markdown files, symbolic links and special entries, and applies supported literal Planisphere `excludedPaths` paths. Excluded locations and unsupported filters are visible in Pruning. The graph runs on a private, disposable copy of verified Markdown; links resolve only to included notes. The scan fingerprint covers discovery content and scope, not attachment bytes or whole-folder write eligibility. Structural guidance is advisory, including preservation of chronology and proof chains.
- Discovery is bounded to 20,000 notes, 256 MiB of text, 8 MiB per note, 250,000 visited entries and 128 folder levels. The report lists up to 100 excluded locations and 200 candidate groups, with total counts and truncation disclosed. A listed excluded directory represents its entire subtree. No excluded target is followed to assess its contents.
- Optional authority review, preparation and application retain strict whole-vault inventories. They still refuse symbolic links and special files and retain full attachment/configuration freshness checks. A candidate scan can succeed while authority review is unavailable. Native checkpoint support for links does not change Grapheine's write contract.
- Every process receives one explicit selected vault; no default or multi-vault registry resolution is used. The selected policy must bind that same root. New scan, policy, question or vault selection invalidates prepared changes and any loaded permission.
- The adapter additionally holds operations that would rewrite code examples. The pinned toolkit's link parser does not distinguish every literal code example from a live link; the native integration must not silently alter those examples.
- An apply failure does not imply that nothing changed. Keep the recovery checkpoint and inspect any completed commit named by Grapheine. If application succeeded but the second checkpoint or UI refresh failed, the app preserves the success result and explains the follow-up failure.
- Before invoking a write, the app persists a per-vault attempt reminder with packet digest, recovery checkpoint ID and start time. An unconfirmed attempt remains visible after relaunch and scans. This preference is a recovery reminder, not a transaction journal or proof of completion. Only a confirmed engine result clears it.
- Scan timeouts never authorize a write. An apply process is not killed by a routine scan timeout. Keep the app open until it finishes.
- The existing local checkpoint format preserves `.git` as ordinary included files. This can increase checkpoint work and storage for Git vaults; no history compaction or deletion is performed.

## Engine and runtime

Bundled engine: Grapheine `0c96ff9d4c9fbce0a275268d88299143d56292d4` (one link rule, `graph measure`; version stays 0.28.0 until the engine release), with both Python modules checked against fixed SHA-256 values by packaging and the bridge. The bundle includes its MIT license and authority contract. Source is copied from the local reviewed checkout during packaging; there is no runtime download or update.

Python 3.9+ is currently an external dependency. The default interpreter is `/usr/bin/python3`; development can select an absolute executable with `PLANISPHERE_PYTHON`. Signed authority verification requires `cryptography`; write operations also require local Git. The app surfaces missing dependencies instead of returning a successful empty scan. A bundled standalone runtime and clean-machine acceptance are prerequisites for public distribution of pruning.

The process adapter uses argument arrays, fresh processes, private temporary output files, bounded read-only operation time, and a cleaned environment. It removes inherited Git, Graphite and Python overrides. This is ordinary local process hygiene, not a security boundary against an unrestricted same-user process.

## October 10 local acceptance

- Swift: 22 XCTest cases and 12 managed-reference cases passed. Seven of the XCTest cases cover Grapheine transport, parsing, scope identity and safe note previews. The subprocess transport fixture does not verify signatures; the Python and native journey below exercise the real verifier.
- Python bridge: 16 cases passed, including exact signed application, wrong scope/permission, stale attachments, non-Git refusal, affect/evidence holds, literal code preservation, invalid Markdown, special files, missing signing dependency and a verified completed commit followed by index-refresh failure.
- Packaged native app, disposable vault: scanned six notes, inspected a two-note candidate group, loaded the existing fixture policy, prepared the real two-file packet, inspected before/after link changes, loaded its separately signed fixture permission and applied it. Native History showed Before pruning and After pruning checkpoints. Restoring the earlier checkpoint to a new folder recovered the retired note and original backlinks; direct byte/hash checks confirmed all six original note files and the original local Git HEAD. The new vault did not inherit the policy selection.
- Fixture packet `e0460e1ca168e70771a1eb9e1ad12f7877dfdd9bee9b3860f3aa871d85a67b64`; completed local commit `e4a5b0eb5082258d2e4da225f8b4dc3976b2f849`. The fixture had no remote. These test-only signatures are not operator enrollment.
- The main app was reopened on 0.2.0. A read-only Mythology-Graph scan returned 260 Markdown notes and no matching-account groups. Its existing 265-file checkpoint remained available. No live-vault prune or trust provisioning was performed.

Limits at the 0.2.0 acceptance: ad-hoc signing, external Python runtime, and Git-only signed settlement; ordinary folders then had discovery/review only. Version 0.4.0 adds the separate native local-review path above. Neither fixture acceptance nor the presence of context policy instructions establishes an enforceable security boundary.

## October 10 mixed-vault regression

The 0.2.0 scan incorrectly required a strict full-folder write inventory before read-only discovery. A hidden development checkout's symbolic link stopped discovery, even though the graph would skip that directory. The 0.3.0 discovery scope separates those checks without changing signed writes. Twenty-five Python bridge cases passed, including external-link non-reading, no binary hashing, exclusions, changed scope, and continued strict authority/write refusal. A direct read-only scan of `planisphere-build` completed in 0.94 seconds with 973 included notes, 59 candidate groups, and 14,646 excluded locations. These counts describe the inspected source state, not a permanent corpus total.
