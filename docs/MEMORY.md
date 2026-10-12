# Local memory

Memory is available from the shared sidebar, Workspace menu, and command palette.
An empty installation opens Memory without requiring an account or an existing
vault. Vault history, graph, pruning, Prompts and Hooks retain their existing
surfaces. The first version provides:

- A private local profile, SQLite authority and inspectable Markdown projections.
- Personal and project scopes, attributed source excerpts, revision-checked
  corrections, replay-safe operations and recovery after interrupted writes.
- Inspect, add, edit, forget, pause saving and paginated JSON export controls.
- Account-free Codex setup using the existing shared controller. It preserves
  recognized task owners, disabled events and unrelated hooks.
- Bounded memory retrieval inside a shared per-turn context byte budget.

The host runtime is pinned by `Integrations/Host/PIN.json`; packaging verifies
every source fingerprint before copying it. Set `PLANISPHERE_HOST_SOURCE` to the
reviewed API checkout's `internal` directory when packaging. The app bundles its
own Python runtime and `planisphere-memory` executable. The helper is signed as
part of the normal inside-out app signing process.

## Ownership and scope

Default state is `~/Library/Application Support/Planisphere/Memory`, independent
of sign-in. `PLANISPHERE_DATA_DIR` relocates it for disposable app acceptance.
The Mac app creates the profile identity and pins its bundled helper in a private
`connection.json`. The host cannot supply a different storage path in requests.
Filesystem canonicalization uses `realpath`; Foundation URL normalization can
otherwise turn `/private/tmp` into a symlink alias rejected by the adapter.

The host retrieves personal memories and its explicit project route, or the
current working directory when no route exists. Paths establish retrieval scope,
not permission. Model proposals stay `agent_interpretation`; exact source-excerpt
validation is not proof that an interpretation is correct or human-authorized.
Direct Mac editor input is labeled `human_statement`. Tasks stay in their
existing host store; memory holds pointers, not copied task authority.

The prototype's schema 1 upgrades to schema 2 transactionally; existing records
receive personal scope and keep their original contents. The older prototype
cannot reopen a migrated store. The private profile is local plaintext and does
not provide device-loss backup, account synchronization or at-rest encryption.

## Delivery, pause and deletion

The default combined hook ceiling is 12,000 UTF-8 bytes, including memory/task
context, response evidence, descriptors and repeated attempts sharing the ledger.
These are bytes, not token estimates or all frontier-model usage. Omitted content
has a recovery path and is never acknowledged as delivered. Evidence bundles in
the library track declared requirements, versions and acknowledgments; they do
not certify semantic completeness. Automatic Grapheine closure planning and
Graphite mutations are not installed by this first slice.

Pause prevents new memory records, task pointers and evidence declarations.
Reading, forgetting and recovery of already accepted operations remain available.
Forget tombstones owned records, purges their revisions and dependent bundles,
and removes generated copies whose contents still match. Edited copies are
preserved with a visible pending-deletion state. Original chats, authoritative
tasks and separate exports remain outside this deletion scope. Newly worded
semantic duplicates are not automatically detected.

## Local support preview

The Memory screen includes a separate Local support setup sheet. It lists loaded
device-local LM Studio models and offers observation, prepared-evidence use and
pause. Fresh memory setup is sufficient; no account or existing vault is required.
Connecting support upgrades recognized existing agent controllers, preserves
disabled events and requires normal Codex hook review. Opening Memory reads saved
support status without waking the model; opening setup checks the local inventory.

Native support snapshots contain bounded current records and declared dependency
groups for explicit personal/project scopes. Missing or changed members remain
gaps. Preferences, decisions, corrections and qualifications cannot be filtered
out by the local model. When every item is required, deterministic code skips
generation. Otherwise a background worker may prepare a smaller source selection.
The foreground does not wait for generation, and a prepared selection does not
acknowledge host delivery or establish answer quality.

This remains a preview: only synthetic local inference and host journeys have
been measured. The whole-workflow frontier-token, metered-cost and independent
quality gates remain unmeasured. LM Studio is an external runtime dependency;
no model weights are included in this app package. Pause stops new preparation
and prevents stale publication; an in-flight provider request may finish within
its configured limit.

## Acceptance and release boundaries

Run the full Swift suite with the release-pinned Grapheine engine, plus
`integration/validate_memory.py` against a debug helper and the pinned host
runtime to exercise interrupted commits, deletion, concurrency and stale offers.
The private API review contains additional native helper/host integration and
combined-budget tests. Packaged acceptance should cover first use, setup,
editor save, refresh/restart, and a synthetic prompt using only disposable state.

The app observes installed and disabled hook configuration. It does not claim
that Codex has trusted or automatically run those hooks. Normal host review and
an actual lifecycle observation remain separate acceptance steps. Do not set
trust flags or equate a manually invoked test prompt with automatic activation.

The current candidate is locally ad-hoc signed. Public Mac source/version push,
Developer ID signing, notarization and public download acceptance remain subject
to the existing release hold and release workflow. This feature needs no API
database migration and does not change production traffic.
