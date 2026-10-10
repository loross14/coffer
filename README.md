# Planisphere for Mac

Local vault management and version history. Add a folder, make a checkpoint, inspect what changed, restore a recovered copy, and export the vault with its retained history. No GitHub account or managed-storage subscription is needed.

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

Vault folders remain ordinary files. Planisphere stores its registry and content-addressed checkpoint history separately in `~/Library/Application Support/Planisphere`. Removing a vault from the list preserves its files and history. Re-adding the same folder recovers its identity/history. Explicit checkpoints capture included hidden files and attachments; they do not promise to record every edit. The app explains unsupported files instead of silently following links.

Restoring creates a **new recovered folder**, leaving current work untouched. Export produces the latest saved checkpoint as ordinary vault files plus inspectable retained history. Edits made after that checkpoint are not included; create another checkpoint first to include them. Saved history can be exported even if the working folder is unavailable. Checkpoints on the same device are not an independent backup; keep a separate backup appropriate for the data.

For isolated development/UI testing, `PLANISPHERE_DATA_DIR` selects a separate history root and `PLANISPHERE_DEMO_VAULT` explicitly selects a disposable fixture to register. The app never auto-imports actual user vaults.

## Grapheine pruning

The **Pruning** workspace scans the selected vault with Grapheine, presents nominated groups and readable note previews, and surfaces curatorial guidance. Scans work on ordinary local folders without an account, GitHub or an authority policy. Matching names nominate candidates; they never trigger deletion.

For the existing signed settlement workflow, connect an independently provisioned local authority policy. The app shows its questions, decisions and preservation holds; an eligible decision can produce an exact before/after packet for export and separate signing. Load the signed permission and review the changes before applying. Planisphere saves a current checkpoint first, calls the existing verifier, and saves another checkpoint after success. Recovery restores a new copy.

**Current write limitation:** Grapheine's signed settlement still requires the vault itself to be a clean local Git root, plus a signed decision and separate exact-change permission. No GitHub remote is needed. The app does not initialize Git, create signing keys, provision trust, or upload vault contents. Pruning writes for ordinary non-Git vaults remain future work; native checkpoints alone do not replace Grapheine's signed Git receipt history. [Integration details](docs/GRAPHEINE.md).

This local candidate bundles the reviewed Grapheine source but uses installed Python 3.9+ (`/usr/bin/python3`, or `PLANISPHERE_PYTHON`). Signed operations also require Python's `cryptography` package and local Git. A standalone Python runtime is not bundled, so clean-machine distribution of this feature is not yet complete. Packaging requires the reviewed sibling `Grapheine` checkout or `PLANISPHERE_GRAPHEINE_SOURCE`; exact engine hashes are checked.

## Managed, in parallel

`PlanisphereManaged` is a separate reference implementation and test target for verified objects, tenant/vault isolation, expected-parent publication and idempotent retry. It is not linked into the Mac app. There is no hosted managed service or upload switch in this build. Shared `VaultFormat`, vault IDs and checkpoint manifests allow a later opt-in service without cloud dependencies in the local checkpoint path. See [managed protocol](docs/managed-protocol.md).

Local app licensing and optional managed pricing are undecided. Local functionality is independent of managed-service readiness.
