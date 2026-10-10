# Planisphere for Mac

Local vault management, version history, and an interactive graph. Add a folder, explore its connections, make a checkpoint, inspect what changed, restore a recovered copy, and export the vault with its retained history. No GitHub account or managed-storage subscription is needed.

Planisphere descends from the Coffer prototype. The original `Coffer/` and Xcode project remain as historical source; **the current app is built from `Sources/PlanisphereApp` and `Sources/PlanisphereCore` through `Package.swift`**. It does not invoke Coffer's in-place encryption or migrate Coffer keys/configuration.

## Build and run

Requires macOS 14 or later and a Swift 6 toolchain. Open `Package.swift` in Xcode, or:

```sh
swift test --disable-sandbox
./scripts/package-mac.sh
open dist/Planisphere.app
```

The package script creates a locally signed app and a ZIP in `dist/`. Its default ad-hoc signature is not Apple notarization. External distribution requires a Developer ID signature and notarization; the local build does not claim either.

The [October 10 acceptance record](docs/ACCEPTANCE-2026-10-10.md) records the tested build and native recovery workflow. See [release preparation](docs/release.md) for public distribution requirements and [local storage format](docs/LOCAL-STORAGE.md) for fidelity and recovery limits.

## What stays local

Vault folders remain ordinary files. Planisphere stores its registry and content-addressed checkpoint history separately in `~/Library/Application Support/Planisphere`. Removing a vault from the list preserves its files and history. Re-adding the same folder recovers its identity/history. Create Checkpoint defaults to **Markdown Only**: included regular `.md` notes and their parent folders, using supported Obsidian exclusions. Attachments, settings, other files and symbolic links stay outside that checkpoint. **Vault Content** adds included settings and attachments; **Whole Folder** remains available for complete-folder capture. The saved scope is shown in History. The broader modes preserve symbolic links as references without following them. Explicit checkpoints do not promise to record every edit.

Restoring creates a **new recovered folder**, leaving current work untouched. Export produces the latest saved checkpoint as ordinary vault files plus inspectable retained history. Edits made after that checkpoint are not included; create another checkpoint first to include them. Saved history can be exported even if the working folder is unavailable. Checkpoints on the same device are not an independent backup; keep a separate backup appropriate for the data.

For isolated development/UI testing, `PLANISPHERE_DATA_DIR` selects a separate history root and `PLANISPHERE_DEMO_VAULT` explicitly selects a disposable fixture to register. The app never auto-imports actual user vaults.

## Graph

The **Graph** workspace reads the selected vault's Markdown links locally. Search by note name or path, select a note to read it, focus its neighborhood, and open it in your editor. Folder colors and initial placement make larger vaults easier to navigate. Drag a note to move it, pin it in place, drag the background to pan, and scroll or pinch to zoom around the pointer.

The native force simulation uses Barnes–Hut repulsion, degree-aware springs, collision separation and local reheating after a drag. It cools to rest and stops its timer; selecting a note does not disturb a settled layout. Pause and spacing controls are available, and Reduce Motion starts the graph paused. Fit changes the camera without resetting positions. Refresh re-reads the vault while preserving surviving note positions and pins for this view session.

The graph is a snapshot, not a live editor or semantic similarity claim. It shows explicit resolved links, with ambiguous, missing, unsupported and omitted counts available under **Snapshot & scope**. No links or vault files are written. [Graph behavior, limits and validation](docs/GRAPH.md).

## Grapheine pruning

The **Pruning** workspace scans the selected vault with Grapheine, presents nominated groups and readable note previews, and surfaces curatorial guidance. Scans work on ordinary local folders without an account, GitHub or an authority policy. Matching names nominate candidates; they never trigger deletion.

For local pruning, explicitly choose the note to keep, prepare the changes, and review every retirement and link update. Apply Reviewed Changes saves a Markdown checkpoint, records a durable operation journal, applies the exact reviewed bytes, and saves the result as another checkpoint. Stale notes or changed exclusions require a new review. Recovery restores the earlier checkpoint into a new folder. Local pruning requires neither Git nor signing-key setup.

Local review covers included Markdown. References from excluded folders, attachments, other vaults and external applications are outside its scope. Grapheine's preservation and affect checks can hold a proposed change; matching names are not proof that two notes mean the same thing. A local click records a local review, not an externally authenticated identity or signed authority decision.

An existing independently provisioned signed authority policy remains an optional, separate mode. Its legacy settlement protocol still uses a clean local Git root, signed decision and exact-change permission. Selecting that mode never silently falls back to unsigned local review. The app does not initialize Git, create signing keys, provision trust, or upload vault contents. [Integration and recovery details](docs/GRAPHEINE.md).

This local candidate bundles the reviewed Grapheine source but uses installed Python 3.9+ (`/usr/bin/python3`, or `PLANISPHERE_PYTHON`). Signed operations also require Python's `cryptography` package and local Git. A standalone Python runtime is not bundled, so clean-machine distribution of this feature is not yet complete. Packaging requires the reviewed sibling `Grapheine` checkout or `PLANISPHERE_GRAPHEINE_SOURCE`; exact engine hashes are checked.

## Managed, in parallel

`PlanisphereManaged` is a separate reference implementation and test target for verified objects, tenant/vault isolation, expected-parent publication and idempotent retry. It is not linked into the Mac app. There is no hosted managed service or upload switch in this build. Shared `VaultFormat`, vault IDs and checkpoint manifests allow a later opt-in service without cloud dependencies in the local checkpoint path. See [managed protocol](docs/managed-protocol.md).

Local app licensing and optional managed pricing are undecided. Local functionality is independent of managed-service readiness.
