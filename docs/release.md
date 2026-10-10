# Mac release preparation

The first Planisphere app release is local vault management. Managed storage is independently developed and is not part of the app's executable dependency graph.

## Local candidate

1. Run `swift test --disable-sandbox` against the selected source.
2. Run `scripts/package-mac.sh` to build a Release app, icon, Info.plist, signature and ZIP.
3. Exercise add/create, checkpoint, comparison, recovered-copy restore, full export, removal/re-add and restart using disposable fixtures and an isolated `PLANISPHERE_DATA_DIR`.
4. Verify included hidden files, binary bytes, empty folders and retained older versions, not just a count of files. Export uses the latest saved checkpoint and all retained history, so exercise it with the working folder temporarily unavailable as well.
5. Check the exact output with `codesign --verify --deep --strict dist/Planisphere.app` and retain the ZIP SHA-256.

By default the build targets the host architecture and is ad-hoc signed for local use. This is not an Apple Developer ID signature or notarized public distribution. The app currently runs without App Sandbox; it reads folders selected in the native folder picker and keeps history in its Application Support directory. It makes no vault uploads and does not contain the prototype's in-place encryption workflow.

## Public distribution

When a valid Developer ID Application identity is available, set `PLANISPHERE_SIGN_IDENTITY` to that identity before packaging. The script adds a secure timestamp for that signing mode. Verify the chosen deployment target and supported architectures, then submit the ZIP with the owner's configured notarytool credentials and wait for a successful result. Staple the accepted ticket to the app, verify Gatekeeper assessment, recreate/checksum the distributable ZIP, and test a clean-machine download and launch. Do not describe an ad-hoc build as notarized, or treat a queued notarization submission as success.

Local history is separate from the working vault, but is still on this Mac. Device-loss backup requires a separate copy; the managed reference library does not provide a hosted backup service. Restore in this first build produces a new registered recovered copy and retains original work. Full in-place rollback is intentionally absent until arbitrary-editor coordination can be established.

## Lineage and update policy

Coffer's original source remains in the repository for provenance. The current app uses the Swift package targets under `Sources/`, a separate `ooo.planisphere.mac` identity, and separate storage. It does not open or rewrite Coffer's registry, encrypted files or Keychain entries. There is no automatic update service in this candidate. App updates must keep the versioned local history format compatible or provide a verified migration before changing it.
