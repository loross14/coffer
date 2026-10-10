# Grapheine integration, 0.2.0

Planisphere for Mac is a local adapter to Grapheine's existing reviewed pruning workflow. It makes no network calls. Managed storage and the hosted console are separate optional surfaces.

## User flow

1. Select a vault and open Pruning. Scan Vault reads its current files; it does not create a checkpoint or change notes.
2. Inspect candidate groups, member text and Grapheine's guidance. The displayed group count distinguishes all nominated groups from the bounded displayed list. Current note previews can change after a scan; the exact operation preview is separately pinned.
3. Optionally connect an existing external authority policy for this exact vault. The app reads declared questions and signed decisions. It never writes the policy, creates a signer, or treats candidate ranking as approval.
4. For a resolved eligible question, prepare the exact changes. The underlying packet pins all included file contents, policy, question manifest, authority log and Git HEAD. Review every retirement and rewritten link; export the packet for the independently controlled signer.
5. Load the signed permission for this exact packet and choose Apply Reviewed Changes. Planisphere captures current working bytes in a checkpoint before invoking the existing apply path. Grapheine re-derives the packet, verifies signatures, freshness, affect holds and evidence preservation, and creates a local Git commit with its signed audit. Planisphere captures a second checkpoint after successful completion.

The underlying contract requires a clean Git vault. No remote or GitHub storage is required. Ordinary folder scans are supported, but in-place pruning writes backed only by native checkpoints are not implemented. Adding that path needs a versioned settlement protocol, preserved original/output snapshots and verifiable transition history, rather than replacing a Git command with a checkpoint call.

## Boundaries and recovery

- Before apply, close editing and sync writers. Grapheine's locks coordinate itself and Git, not arbitrary editors. Multi-file application cannot be atomic against a noncooperating editor. A crash can leave partial working changes and stale locks; inspect the local Git receipt and use the saved pre-operation checkpoint to restore a new folder.
- A scan takes inventories before/after and refuses a changed input. It preflights paths, symlinks, regular files and note decoding before calling Grapheine. Structural guidance is advisory, including preservation of chronology and proof chains.
- Every process receives one explicit selected vault; no default or multi-vault registry resolution is used. The selected policy must bind that same root. New scan, policy, question or vault selection invalidates prepared changes and any loaded permission.
- The adapter additionally holds operations that would rewrite code examples. The pinned toolkit's link parser does not distinguish every literal code example from a live link; the native integration must not silently alter those examples.
- An apply failure does not imply that nothing changed. Keep the recovery checkpoint and inspect any completed commit named by Grapheine. If application succeeded but the second checkpoint or UI refresh failed, the app preserves the success result and explains the follow-up failure.
- Before invoking a write, the app persists a per-vault attempt reminder with packet digest, recovery checkpoint ID and start time. An unconfirmed attempt remains visible after relaunch and scans. This preference is a recovery reminder, not a transaction journal or proof of completion. Only a confirmed engine result clears it.
- Scan timeouts never authorize a write. An apply process is not killed by a routine scan timeout. Keep the app open until it finishes.
- The existing local checkpoint format preserves `.git` as ordinary included files. This can increase checkpoint work and storage for Git vaults; no history compaction or deletion is performed.

## Engine and runtime

Bundled engine: Grapheine `c013207c1fb1140fd20819fb61e1b7a25980ea88`, with both Python modules checked against fixed SHA-256 values by packaging and the bridge. The bundle includes its MIT license and authority contract. Source is copied from the local reviewed checkout during packaging; there is no runtime download or update.

Python 3.9+ is currently an external dependency. The default interpreter is `/usr/bin/python3`; development can select an absolute executable with `PLANISPHERE_PYTHON`. Signed authority verification requires `cryptography`; write operations also require local Git. The app surfaces missing dependencies instead of returning a successful empty scan. A bundled standalone runtime and clean-machine acceptance are prerequisites for public distribution of pruning.

The process adapter uses argument arrays, fresh processes, private temporary output files, bounded read-only operation time, and a cleaned environment. It removes inherited Git, Graphite and Python overrides. This is ordinary local process hygiene, not a security boundary against an unrestricted same-user process.

## October 10 local acceptance

- Swift: 22 XCTest cases and 12 managed-reference cases passed. Seven of the XCTest cases cover Grapheine transport, parsing, scope identity and safe note previews. The subprocess transport fixture does not verify signatures; the Python and native journey below exercise the real verifier.
- Python bridge: 16 cases passed, including exact signed application, wrong scope/permission, stale attachments, non-Git refusal, affect/evidence holds, literal code preservation, invalid Markdown, special files, missing signing dependency and a verified completed commit followed by index-refresh failure.
- Packaged native app, disposable vault: scanned six notes, inspected a two-note candidate group, loaded the existing fixture policy, prepared the real two-file packet, inspected before/after link changes, loaded its separately signed fixture permission and applied it. Native History showed Before pruning and After pruning checkpoints. Restoring the earlier checkpoint to a new folder recovered the retired note and original backlinks; direct byte/hash checks confirmed all six original note files and the original local Git HEAD. The new vault did not inherit the policy selection.
- Fixture packet `e0460e1ca168e70771a1eb9e1ad12f7877dfdd9bee9b3860f3aa871d85a67b64`; completed local commit `e4a5b0eb5082258d2e4da225f8b4dc3976b2f849`. The fixture had no remote. These test-only signatures are not operator enrollment.
- The main app was reopened on 0.2.0. A read-only Mythology-Graph scan returned 260 Markdown notes and no matching-account groups. Its existing 265-file checkpoint remained available. No live-vault prune or trust provisioning was performed.

Remaining distribution/workflow limits: ad-hoc signing, external Python runtime, and Git-only signed settlement. Ordinary non-Git vaults currently have discovery/review only. Neither this acceptance nor the presence of context policy instructions establishes an enforceable security boundary.
