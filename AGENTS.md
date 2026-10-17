# Planisphere for Mac — working here

This is the **only** Mac app checkout to edit: `/Users/logan/planisphere-worktrees/repos/planisphere-mac`, branch `main`
(GitHub `loross14/coffer`, bundle ID `ooo.planisphere.mac`). Consolidated 2026-10-17; the previous 28 worktrees
and temp clones were removed, their branches merged or archived. Do not create new worktrees inside the
`planisphere-build` knowledge graph (code left it on 2026-10-17); task worktrees go under `/Users/logan/planisphere-worktrees/`, sibling repos sit beside this one under `repos/`.
`CLAUDE.md` is a symlink to this file.

## Orientation
- App code: `Sources/PlanisphereApp` (SwiftUI), `Sources/PlanisphereCore`, `PlanisphereGraph`, `PlanisphereGrapheine`,
  `PlanisphereMemory` (+ `MemoryCLI`, `ModelLauncher`). `Coffer/` and `Coffer.xcodeproj` are the historical prototype; never build from them.
- Bundled runtimes: `Integrations/Host/PIN.json` (planisphere-api `internal/` commit + file hashes),
  `scripts/bundle-grapheine.py` `PIN` (Grapheine engine commit), `Integrations/Model/PIN.json` (llama.cpp server).
  Changing a pin means regenerating the hash list from `git archive <commit> internal` and the bundler's `FILES`.
- Version lives in `Resources/Info.plist` (`CFBundleShortVersionString` / `CFBundleVersion`). Build numbers only go up;
  the appcast build must exceed every installed build. Shipped: 0.9.11 (32) on 2026-10-17.
- Docs worth reading before a change: `docs/ONBOARDING.md`, `docs/MEMORY.md`, `docs/CONSOLE-CONNECTION.md`,
  `docs/WORKSPACE-UI.md`, `docs/LOCAL-STORAGE.md`, `docs/release.md`.

## Build, test, package
```sh
swift test --disable-sandbox                       # full suite (≈220 XCTest + 13 Swift Testing)
source scripts/release-env.sh                      # exports every PLANISPHERE_* input; pins engine + host worktrees under .build/pins
./scripts/package-mac.sh                           # Release build → dist/Planisphere.app + dist/Planisphere-<ver>-mac.zip (+ .sha256)
/usr/bin/python3 scripts/check-package.py dist/Planisphere.app
```
`release-env.sh` reads the pins from this tree and the Sparkle public key from the installed app, uses the pinned
Python runtime in `.build/python-runtime.tar.gz` + `.build/python-wheels`, and the prebuilt model server in
`/Users/logan/planisphere-releases/builtin-model-2026-10-14/model-server/`. Sibling repos it pins from:
`../planisphere-api`, `../Grapheine` (both fetched, never checked out or modified). Sparkle tools land in
`.build/artifacts/planisphere-mac/Sparkle/bin/` after `swift package resolve`.
Verify candidates headless (check-package, tests, accessibility reads). **Never `open` a candidate beside the installed app**;
one Planisphere runs at a time. After any acceptance launch, quit it and `lsregister -u <path>`.

## Shipping (public line only)
1. Bump version/build in `Resources/Info.plist`; PR to `main`; merge (Logan merges; GitHub Actions is billing-locked, run tests locally).
2. `source scripts/release-env.sh && ./scripts/package-mac.sh`; `check-package.py`; `codesign --verify --deep --strict`.
3. Notarize without the GUI (proven 2026-10-17 for 0.9.12): build an `.xcarchive` around `dist/Planisphere.app`
   (`Products/Applications/Planisphere.app` + an `Info.plist` with `ApplicationProperties`; see
   `planisphere-releases/mac-0.9.12-b33-host-pin-2026-10-17/`), then
   `xcodebuild -exportArchive -archivePath <archive> -exportOptionsPlist ExportOptions.plist -exportPath <out> -allowProvisioningUpdates`
   with `method=developer-id`, `destination=upload`, `teamID=RA46B4WYQ4`, `signingStyle=manual`. It uploads with the Apple ID
   signed into Xcode; the submitted app appears under `<archive>/Submissions/<id>/`. Poll `xcrun stapler staple` on a copy
   every ~45 s until the ticket exists (≈3–6 min), then staple the real app, `stapler validate`, `spctl --assess --type execute`.
   (No `notarytool --keychain-profile` exists; `notarytool history` would need Logan's app-specific password.)
4. Zip the stapled app (`ditto -c -k --keepParent`), `sign_update --account ooo.planisphere.mac <zip>` for the EdDSA signature.
5. Website repo `loross14/planisphere-website` (canonical checkout `../planisphere-website`, `main`): add `mac/Planisphere-<ver>-mac.zip`
   + `.sha256`, new `<item>` at the top of `mac/appcast.xml` then `sign_update --account ooo.planisphere.mac mac/appcast.xml`,
   update `mac.html` (link + checksum), `tools/homepage_release_fragment.inc` → `python3 tools/apply_homepage_release.py`,
   run the repository-integrity gates locally (see `~/.claude` memory `github-actions-budget`), PR; Logan merges → Vercel.
6. GitHub release `v<ver>` on coffer with the zip, sha256 and `Planisphere-<ver>-host-runtime.tar.gz`; Logan publishes.
7. Record: `/Users/logan/planisphere-releases/mac-<ver>-b<build>-<date>/` (RELEASE-NOTES, artifact.json, verification.json,
   notarization-log.json). Do not swap `~/Applications/Planisphere Local.app` unless Logan says "install";
   if you do, follow `planisphere-releases/INSTALLED.json` (CDHash compare, keep the replaced bundle, update the ledger).
8. Verify by content: live appcast top item, served zip SHA-256, `sign_update --verify` on feed and zip, homepage button.

## Coordination
Before touching the install path read `INSTALLED.json` and `git worktree list` here; other agents ship to the same path.
Preserve Logan's custom hooks (`~/.codex/hooks.json`, `~/.claude/settings.json`, `~/.local/state/planisphere/personal-hooks/…`);
the 0.9.11 record has the protected-file hash list. Old builds: `planisphere-releases/archive/mac/` (zipped bundles) and
Xcode Archives in `~/Library/Developer/Xcode/Archives/` (notarization evidence, keep).
