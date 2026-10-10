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
