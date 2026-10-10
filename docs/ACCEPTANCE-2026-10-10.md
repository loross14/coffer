# Planisphere for Mac 0.1.0 — local candidate

Verified October 10, 2026 on macOS 26.5.1, Apple silicon, with Swift 6.3.3 / Xcode 26.6. The deployment target is macOS 14; older supported OS versions and Intel hardware have not been exercised. The packaged executable is arm64.

## Build and checks

- Final `swift test --disable-sandbox`: 15 XCTest cases (including the subprocess helper) and 12 managed contract tests passed, no failures. Filesystem cases include actual process locking, changing captures, corrupt metadata/content, path aliases/collisions, unsafe destinations, and byte fidelity.
- Release product built successfully. The app's dependency graph contains `PlanisphereCore`, with no managed target or third-party packages. Source inspection found no network client in the app or core.
- `codesign --verify --deep --strict` passed on the distributable app. This is ad-hoc signing for local use, not Developer ID or notarization. No Apple codesigning identities were available on the build host.
- ZIP SHA-256: `1b5e46df9ae5b53aba98b2a563c9544f95ae74ce4d6899d9e33b15fd45986482`.

## Native acceptance

The current executable was copied into a separately identified `Planisphere QA.app` and signed for that test identity. It used an explicit disposable history root and fixture vault. The user's running Planisphere window was left alone. The initial split-view layout exposed offscreen controls; the final workspace uses bounded columns and was visually checked after repair.

The native UI was used to add an existing folder, capture two checkpoints, inspect the before/after note contents, restore the first checkpoint to a new registered folder, export the latest saved checkpoint and all history, remove/re-add the original folder, and create a new empty vault. Vault IDs and both original checkpoints survived restart.

The working fixture folder was temporarily moved away before export. Export succeeded from retained history. An edit made after the second checkpoint remained only in the working folder. A temporarily missing test history head produced an explicit unavailable-history state, disabled checkpoint/export controls, and a working Retry action after the original head was returned; it did not create replacement history.

The independent Python verifier checked exact recovered, exported and working file bytes, hidden Obsidian settings, a binary attachment, an empty directory, both retained manifests, all six referenced object hashes/sizes, the current local head, and the original registration UUID. It passed again after restart. It intentionally does not reproduce Swift's canonical metadata-envelope encoding; metadata checksum validation was exercised by the Swift tests and native history reads.

Re-run the completed fixture verification with:

```sh
python3 -B scripts/verify-acceptance.py /private/tmp/planisphere-mac-qa-ts7l6m03 \
  --original-vault-id 830BABBB-74B6-4C4C-9856-50F67FFC376D
```

The fixture is temporary, not part of the app or a permanent backup. Test logs and structured verification output are in the ignored `.build/` directory on this checkout.

## Readiness and boundaries

Ready for use as a local candidate on the tested Mac. Public release still requires the signing, notarization, architecture and clean-machine checks in [release.md](release.md). The managed library is an in-memory reference, not an available hosted service. Checkpoints are explicit; restoration creates a new copy. History is plaintext on this Mac and does not provide device-loss backup. File metadata and compatibility limits are documented in [LOCAL-STORAGE.md](LOCAL-STORAGE.md).

## 0.3.0 — mixed development vault checkpoint repair

The reported failure came from **Create Checkpoint** on `planisphere-build`: a symbolic link in `.pricing-delivery-2026-09-17/planisphere/core` was rejected. A partial inventory also exceeded the existing 250,000-entry cap before finishing the nested development trees. Raising the cap or following the link would not provide a useful vault checkpoint.

The app now preserves symbolic-link target bytes without following them. Create Checkpoint presents Vault Content and Whole Folder for explicit review. Vault Content retains included files and Obsidian settings, applies supported literal Obsidian exclusions, and omits other hidden/dependency folders. The frozen scope is saved in format-2 history and shown again during restore/export. Format-1 history remains readable. Grapheine discovery uses its own bounded Markdown scope, while signed write checks remain strict.

Validation:

- Full Swift run: 33 XCTest cases and 13 managed-reference tests passed. A subsequent fifth link/scope case verified that changing excluded settings during capture also fails closed; the final four scope tests passed again after preserving hidden plugin settings within `.obsidian`. Together these cover 34 distinct XCTest cases. No test writes were made to a live vault.
- Python bridge: 25 cases passed, including scoped discovery, no external target probing, freshness and unchanged signed settlement checks.
- Packaged native UI, disposable mixed folder: created a Vault Content checkpoint (four files, three links), inspected an external link's target preview, restored that checkpoint to a new folder, then captured Whole Folder (five files, four links, including the hidden checkout link). Direct verification confirmed every restored included file and link target, both retained manifests' objects, omitted checkout paths, and unchanged original/external files.
- Disposable fixture `/private/tmp/planisphere-checkpoint-qa-bdv7rfyt`; original vault `B9683F08-C745-4AAC-9A2F-4C2702DEEFCD`; scoped checkpoint `840B5679-7485-4B05-9D75-D0EAD8C56AF9`; whole-folder checkpoint `D768E5CC-A9FC-41D4-A287-F2D9F7DA66BC`. Its `verified.json` records independent content checks, not metadata-envelope re-encoding.
- Independent source review found one settings-subtree mismatch; the final scope now preserves `.obsidian` descendants unless explicitly excluded, with a regression fixture. The final package was rebuilt and reopened. Existing Mythology-Graph format-1 history remained readable.
- Final app on `planisphere-build`: pruning scanned 973 Markdown notes successfully. Checkpoint review completed in about two seconds and showed 15,409 files, 935 folders, 13 links, 4.01 GB and 207 excluded locations. These are observed estimates; capture validates the selected contents again. The reviewed scope was left for the user to accept before saving a live checkpoint.
- Final local ZIP SHA-256: `2706c419b5e50c7d8c2dcf49d5529eb12497da53de415772c135fa49743f54f3`. Packaging verified the ad-hoc signature. The app remains a local candidate, not a notarized public release.

## 0.3.1 — Markdown as the default

Logan then requested Markdown-only capture. Create Checkpoint now defaults to Markdown Only, with Vault Content and Whole Folder available as explicit alternatives. Scope version 2 preserves this meaning without reinterpreting existing scope-version-1 checkpoints. The mode includes regular lowercase `.md` files and required ancestors; settings, attachments, symbolic links and other files are excluded. Signed pruning recovery still uses Whole Folder.

- All 38 XCTest cases and 13 managed tests passed. Four new cases cover Markdown-only capture/restore/export, omitted settings still pinning scope, ignored binary edits, special/link non-reading, forged manifest rejection, and exact legacy-scope serialization.
- Packaged 0.3.1 reopened with the existing Mythology-Graph checkpoint readable. The build vault's native review defaulted to 974 Markdown notes, 354 folders, zero symbolic links and 6.6 MB. Saving completed successfully as checkpoint `41355F6A-6391-4798-B5E7-55B718678F87` on vault `352E1853-3EB0-4A58-8F02-0AFC94E21405`. The earlier 4 GB proposal was not saved.
- The saved manifest was independently checked for scope version 2, only `.md` regular files and required parent directories; every stored file object's bytes and SHA-256 were verified. No source note or attachment was changed by capture.
- Local ZIP SHA-256: `1b1c99fc01ec7a80ac2d79519abee618ff0b4f2cd2f5b24a7617d2461001b749`; ad-hoc signature verification passed. Public-distribution limits remain unchanged.

## 0.4.0 — local pruning without Git

Logan rejected Git as a prerequisite for vault pruning. Ordinary local vaults now use an explicit keeper selection, an exact change preview, and native Markdown checkpoints before and after applying the reviewed changes. No Git repository, signing key, policy file, or hosted account is required for this path. The optional external signed-policy path remains separate and retains its legacy contract.

- The full Swift suite passed: 53 XCTest cases and 13 managed-reference tests. Coverage includes non-Git pruning and byte-exact restoration, stale reviews, settings changes, interrupted operations, a real subprocess crash, concurrent edits, retained originals, recovery acknowledgment, and tampered packets. After the final targeted reference checks were added, all four local pruning service tests passed again against the real bridge.
- Python checks passed: 25 existing bridge cases, 13 local pruning integration cases, and 10 targeted reference-guard cases. Unrelated links elsewhere in a vault no longer block every candidate. Unsupported references that may target a retiring note still hold the affected review. Canvas content, ambiguous references, unique evidence or attachments, affect checks, and code-literal preservation remain guarded.
- The packaged native app was exercised under a separate QA identity on `/private/tmp/planisphere-native-prune-qa-8qajk_ud/Ordinary Vault`, using disposable history. The UI scanned the vault, accepted an explicit keeper, displayed retirement and backlink rewrites, applied the confirmed review, and restored its pre-prune checkpoint into a new folder. The fixture had no Git repository or signing policy.
- Original fixture vault: `3F05DF8E-8F7E-47D2-8F23-8ABDF68E2C5E`; completed mutation: `3A4D216A-A43B-40FA-B39B-7F3A04A5345E`; before checkpoint: `586FFD33-0C8A-4C1C-992D-2E667ADA0388`; after checkpoint: `FB34D819-D34F-4F56-B817-9E54536F9427`. Restored vault: `6D13112E-FDF4-4FCF-AE5A-D41227E2858F` at the fixture's `Recovered Notes` folder.
- Independent verification in the fixture's `verified.json` confirmed every restored Markdown byte matched the original, the applied backlinks and retirement were exact, native checkpoint objects matched their hashes and sizes, and retained original files were intact. Excluded notes, settings, binary attachment, symbolic link and its external target were unchanged. The native apply/restore check preceded the final targeted-reference refinement; that refinement was covered by the subsequent Swift service and Python regression runs above.
- The final app was rebuilt, signature-verified and reopened on `planisphere-build`. Existing history remained readable and the live vault scanned successfully. A read-only candidate preview reached a relevant incoming-reference preservation hold, rather than requiring Git or failing on unrelated folder links. Keeper selection was cleared afterward. No live vault notes were pruned during this work.
- Final version: 0.4.0, build 5. Local ZIP SHA-256: `26d7ebd083a6174500fed41857ad56953c0ee8e15365029e463f38a9e7bb4573`. This remains an ad-hoc-signed local candidate; public-distribution limits remain unchanged.

Mutation journals and pre-prune checkpoints are durable before source changes begin. Replaced or retired file inodes are retained in hidden sibling recovery files, preserving late editor writes for inspection. An interrupted operation blocks further pruning until its recovery records are explicitly acknowledged; acknowledgment does not automatically replay or roll back edits. See [GRAPHEINE.md](GRAPHEINE.md) for this recovery flow and the distinction between local review and external signed authority.

## 0.5.0 — native graph exploration

Added a Graph workspace for local Markdown vaults, with folder colors and starting positions, direct-link neighborhoods, search, current-note previews, drag/pin, pan, cursor-centered zoom, Fit, spacing, pause and explicit refresh. It uses a pure Swift force engine and the existing bounded read-only discovery scope. No Git, authority policy, account or hosted graph service is required.

- The full Swift run passed 69 XCTest cases and 13 managed tests. Eleven physics tests cover stable integration, collision separation, deterministic layouts, pins, local drag reheating, sleep, dense graphs, compact isolates and folder separation. Five graph-service tests cover response/path/count validation, actual bridge extraction, scope fidelity and cancellation with removal of temporary note copies. Existing checkpoint, pruning and signed-operation checks remained green.
- Python passed all 58 cases: 10 graph-adapter, 25 bridge, 13 local pruning and 10 local guard tests. Malformed repeated link delimiters were independently tested and repaired to avoid quadratic scans; code/HTML literals, dotted filenames, encoded paths, ambiguity, exclusions, exact read-only behavior and 10,001-node truncation were covered.
- Optimized engine-only measurements on this Mac were approximately 0.7–0.9 ms per step at 1,000 sparse nodes and 3.8–4.4 ms at 5,000 nodes. A 1,000-node, 24,000-edge dense fixture measured about 1 ms per step. A six-folder, 900-node fixture settled after 327 steps with at least 822 points between folder centers and a largest group RMS radius of 142 points. These are synthetic layout measurements, not end-to-end rendering timings or a comparison with Obsidian.
- Native acceptance used `/private/tmp/planisphere-graph-qa-7ug0wkl0/Graph Garden`, registered only in a separate QA app/history as vault `DB787C54-E1D9-4AB7-BECE-D395A3C29D59`. The final release executable displayed 1,000 notes and 2,196 directed links. The initial dense starting layout was improved to separate folder groups and compact unlinked notes. A settled note selection retained At rest; exact-path search distinguished identically named Overview notes; neighborhood mode showed 22 notes and 42 links for the selected fixture hub.
- Native paused dragging moved the pinned note to the requested position. Scroll zoom retained the note under the pointer and no longer jumped to a scale limit after a large wheel event. Drawing remained clipped to the canvas. A refresh after a deliberate fixture-only text edit updated the selected preview while retaining its pin; the original fixture bytes were then restored. The source verifier confirmed all 1,003 regular files, the symbolic-link target and absent external target remained unchanged by graph use. No Git metadata was created. `verified.json` in the temporary fixture records those checks.
- The final main app reopened with existing history intact. `planisphere-build` displayed 986 notes and 1,858 links; switching away during a refresh showed only the selected Mythology-Graph's 260 notes and 2,025 links. Returning displayed the build vault's graph correctly. The app was left on the build vault's Graph tab. No live note was edited by this graph work.
- Final version: 0.5.0, build 6. Local ZIP SHA-256: `68a3c94596287565f52a216028a7b0850789c1d4147b78645608f48f7dc1f0bc`. Release build and ad-hoc signature verification passed. The native icon packaging step required normal sandbox escalation on this Mac. Public signing/notarization and clean-machine distribution limits remain unchanged.

The graph is an explicit snapshot of supported Markdown references. Folder layout is visual organization, not semantic similarity. Unresolved, ambiguous, unsupported, excluded and omitted counts are available in the scope popover. Pins and layout are temporary view state. The 10,000-node/100,000-edge display ceilings are bounded protocol limits; native acceptance here exercised 1,000 nodes, not the maximum rendered load. See [GRAPH.md](GRAPH.md).
