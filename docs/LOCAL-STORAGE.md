# Local vault history, formats 1 and 2

Planisphere registers ordinary local folders without rewriting them. Users edit in their existing editor and explicitly create checkpoints. A checkpoint records included regular file bytes, an executable flag, relative paths, directory entries, and—in the broader modes—empty folders and symbolic-link target bytes without following the link. No account, Git repository, network service or Coffer encryption path is involved. Removing a vault from the app archives its registry entry; its folder and saved history remain. Adding the same folder reactivates the same identity.

## Review the capture scope

Create Checkpoint defaults to **Markdown Only**: regular files ending in `.md` and their parent folders, with hidden folders (including `.planisphere`), dependency folders, and supported Planisphere excluded paths omitted. It does not capture attachments, settings, other file types or symbolic links, including links named `.md`. A recovered Markdown Only copy can therefore contain references to attachments that were not captured. The app reads the exclusion settings to define scope but does not store those settings as vault content in this mode.

Two broader modes remain available in the review. **Vault Content** preserves notes, attachments and root `.planisphere` settings unless explicitly excluded, while excluding other hidden folders, `node_modules`, `__pycache__`, and supported literal paths from `.planisphere/scope.json` → `excludedPaths`. **Whole Folder** retains the original complete-folder behavior, including hidden files and folders. These broader modes preserve symbolic links themselves and refuse other special files such as sockets and FIFOs. Link targets' contents are not captured through links.

The review shows estimated included counts and bytes, excluded root counts and up to 200 excluded paths. Excluding a directory excludes its subtree; counts do not imply every descendant was inspected. Regex, wildcard and other unsupported Planisphere filters are listed and are not applied. The user must choose Save Checkpoint after review. No source file is moved or deleted. The settings hash is checked again before and after capture; changed exclusions require a new review.

A scoped checkpoint stores its frozen `captureScope` rules and configuration hash in the manifest. Scope version 1 retains the original Vault Content rules; scope version 2 means Markdown Only. New Planisphere-owned settings use version 3 for Vault Content and version 4 for Markdown Only. Versions 1 and 2 remain readable for recovery; an old mutation review must be recreated before writing. A nil scope means Whole Folder. Existing scopes are not reinterpreted. Scoped checkpoints cannot recover excluded content; History labels their scope, and restore/export use only their included entries. Local reviewed pruning uses Markdown Only checkpoints with the same frozen scope as its review. The separate legacy signed-policy path retains Whole Folder recovery checkpoints. Older apps cannot read the new version 3/4 scopes; use this build for new checkpoints and recovery.

A checkpoint is a storage version, not permission for autonomous semantic changes. Local pruning requires a separate explicit choice and exact-change confirmation. This implementation has no authority activation, remote storage or sync. Local history on the same disk does not protect against device loss.

## Store and identities

The app supplies an Application Support store outside every working vault. Its root is mode 0700; new internal directories are 0700 and files 0600. Saved content is **plaintext**, protected by the user's filesystem permissions and any disk-level protection the user has configured. Do not describe it as encrypted by Planisphere.

```text
<store>/
  registry.json
  .lock
  objects/<sha256>
  vaults/<vault UUID>/
    head.json
    checkpoints/<checkpoint UUID>.json
```

Vault and checkpoint UUIDs are stable identifiers. A checkpoint includes `formatVersion`, `id`, `vaultID`, optional `parentID`, creation time, user message, sorted file entries, optional restoration origin and optional capture scope. Each regular-file entry includes SHA-256 of its exact bytes, byte count and executable flag; directories have no digest. A `symbolicLink` entry's object contains its exact nonempty, NUL-free target bytes, limited to 64 KiB. Identical bytes share immutable objects. Whole-folder checkpoints without links retain format 1. Links or explicit scope use format 2; existing format-1 history remains readable. Older app builds and the current managed reference reject format 2. Every new checkpoint extends the published head. A newly registered vault has an explicit head with no checkpoint ID; a missing head is corruption, not an empty history.

Registry, head and checkpoint files use a JSON envelope `{ "payload": ..., "sha256": ... }`. The checksum covers `VaultFormat.encode(payload)`: sorted-key pretty JSON without slash escaping; dates are Unix seconds including fractions. It detects accidental corruption; it is not an authenticated signature. Objects are named by lower-case SHA-256 of raw bytes. Managed implementations must preserve the same vault/version identities, fields and object bytes; the optional managed reference target is not connected to the app. Compatibility validation remains necessary: the reference transport rejects control characters in names that the local store currently accepts. A local checkpoint is not an unconditional promise of managed upload eligibility.

## Checkpoint capture and publication

A nonblocking OS process lock serializes cooperating Planisphere operations. File traversal is descriptor-relative and rejects symbolic links in roots and ancestors. Included links are read with `readlinkat`, never dereferenced; sockets, FIFOs and other special files are refused. Existing folder paths are canonicalized; device/inode ancestry also checks aliases when separating store and vault. Case/Unicode-colliding paths are rejected even on case-sensitive disks, so a future copy cannot silently merge them on ordinary macOS filesystems.

The store streams file bytes in 1 MiB chunks to new immutable objects, hashes them, checks file/directory metadata before and after reads, and performs a second full inventory and hash pass. Differences abort publication. Checkpoint manifests are published first, then the head; file and directory synchronization is used at publication boundaries. A crash before head publication may leave unreferenced objects or manifests, which do not become visible history. No automatic deletion or garbage collection is implemented.

This is a validated capture for ordinary concurrent editors, not a filesystem-wide atomic snapshot or a boundary against a hostile process with the same user's unrestricted access. Editing may continue after the captured state. The app does not promise to version every edit. For a known checkpoint, pause external edits and retry if capture reports a change.

Every history read validates the complete published parent chain, metadata checksums, path rules, object sizes and object hashes. Corrupt or missing metadata and objects fail closed; the app does not silently create replacement history. It preserves existing bytes for diagnosis. The history screen shares one fully verified read across its list, recovery records, comparison and preview. It does not retain a validation cache across requests. History loading is cancellable, and other workspace navigation remains available while it runs.

## Restore and export

Restore makes a **new** ordinary folder and registers it with a new vault UUID, a first checkpoint and `restoredFrom` linking the original vault/checkpoint. It never restores in place or overwrites newer working files. The destination must not exist and must be outside the store and all registered vaults. A sibling staging folder is built and validated first; exclusive rename refuses a destination that appears before publication, including an empty directory. The original vault and its full history remain unchanged. Regular files and directories are created before links; no entry may have a symbolic link as a parent. Absolute and external link targets retain their exact original reference, so opening such a link later can access an original or external location. The referenced target is not a recovered copy.

Export also requires a new destination. It exports the **latest saved checkpoint** and all published history, including earlier content later changed or deleted. Unsaved working files are excluded. Export does not create a checkpoint and remains available when the original working folder is missing. Create at least one checkpoint before exporting.

```text
<export>/
  files/                         # ordinary latest-saved vault copy
  history/
    export.json                  # envelope: formatVersion, VaultRecord, currentCheckpointID
    checkpoints/<UUID>.json     # every checkpoint in the published parent chain
    objects/<sha256>             # every file object referenced by that chain
```

`files/` opens directly in an ordinary editor. It contains the latest checkpoint's included files, empty folders and links. `history/export.json` includes the original local source path as provenance. Export includes all retained manifests and referenced objects without requiring the app's registry or original source device. External link targets may still depend on the original machine or files. Neither format yet provides an import-history UI. A plain-folder import starts a new registered identity; it must not be represented as preserving an exported history chain automatically.

Create/restore folder publication and registry publication span two filesystem locations. If the folder completes but registration fails or the process stops, the completed new folder can remain unregistered, with possible unreferenced history. Add the folder to continue; that starts a new identity if the registration never committed. No partial operation deletes the original or replaces an existing destination. Staging cleanup is best-effort; interrupted staging and orphan objects are retained rather than automatically purged.

## Limits and fidelity

- Up to 250,000 entries per checkpoint; encoded metadata envelopes are limited to 64 MiB before publication. Total byte counts must fit Int64. Available disk space is an additional practical limit; failures preserve already published history.
- Text previews are limited to 512 KiB, valid UTF-8 without NUL bytes. Large or binary attachments remain in history and export.
- Byte content, relative filenames, directory presence and executable status are retained. Exact timestamps, owners, ACLs, extended attributes/resource forks, Finder tags, hard-link relationships and arbitrary permission bits are not retained. Source files are not modified. Restored files use private permissions (0600, or 0700 for executables).
- Filenames must be valid UTF-8, contain no traversal components or backslashes, and be unique under conservative Unicode/case folding. Link target bytes are preserved even when not UTF-8; only a valid UTF-8 target has a text preview. Other included special files require user resolution before checkpointing; the app does not silently omit them.
- This release has no in-place restore, every-keystroke capture, multi-device sync, history garbage collection, automatic backup or remote recovery. An optional managed adapter must establish its own durable storage, access, concurrency and recovery guarantees.

## Verification scope

Storage tests use disposable fixtures only. They cover hidden configuration, binary attachments, empty directories, executable status, changed/deleted content, restart, archive/reactivation, restore origin and original preservation, export without the working folder, corrupt registry/head/object and malformed manifests, path collisions and overflow, symbolic-link fidelity and special-file rejection, explicit scope, stale settings, exclusive destinations, process locking, bounded previews, and injected source changes between complete capture passes. These tests verify local behavior; they are not power-loss, filesystem certification, production security or managed-service validation.

## Reviewed source-text repairs (local core API)

`TextMutationPlan` and `VaultStore.applyTextMutation` provide a separate opt-in route for existing UTF-8 source files. The caller supplies an exact reviewed packet, selects supported extensions, and pins the complete entries of a Vault Content checkpoint. Both checkpoints must match the reviewed bytes, sizes, executable flags, directories and symbolic-link targets. Only the declared existing regular text files may be replaced or retired; hidden paths, settings, excluded content, NUL-containing or invalid UTF-8 text and unsupported formats are refused. Code is never executed by this API. This does not add a text-editing UI or change Markdown pruning eligibility.

The shared mutation engine retains the pre-change checkpoint and a durable pending journal before writing. Text repairs retain displaced originals in a hidden `.planisphere-recovery` directory beside each target; this directory is excluded by the existing Vault Content rules. A stopped operation may be partly applied, must be inspected, and is never replayed automatically. Interrupted text repairs and Markdown pruning share the same recovery hold when using one store. Existing exact-byte, path, concurrency and explicit recovery-acknowledgment rules still apply; the API does not independently establish human authorization.

Text plans use mutation-journal format 2. This implementation still reads format-1 Markdown journals without changing their digest encoding. Checkpoint formats remain unchanged. Older mutation readers fail closed on text journals; do not write them into an older installed app's store without updating that reader. A project-specific store can use this local API with its own explicit vault identity and recovery location, while the installed app keeps its existing history. Such stores are separate histories, not synchronized replicas or automatic device-loss backups.
