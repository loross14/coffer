# Local vault history, format 1

Planisphere registers ordinary local folders without rewriting them. Users edit in their existing editor and explicitly create checkpoints. A checkpoint records regular file bytes (including dotfiles, hidden configuration, attachments and extensionless files), an executable flag, relative paths, and directories including empty ones. No account, Git repository, network service or Coffer encryption path is involved. Removing a vault from the app archives its registry entry; its folder and saved history remain. Adding the same folder reactivates the same identity.

A checkpoint is a storage version, not permission for autonomous semantic changes. This implementation has no authority activation, remote storage or sync. Local history on the same disk does not protect against device loss.

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

Vault and checkpoint UUIDs are stable identifiers. A checkpoint includes `formatVersion`, `id`, `vaultID`, optional `parentID`, creation time, user message, sorted file entries, and optional restoration origin. Each regular-file entry includes SHA-256 of its exact bytes, byte count and executable flag; directories have no digest. Identical bytes share immutable objects. Every new checkpoint extends the published head. A newly registered vault has an explicit head with no checkpoint ID; a missing head is corruption, not an empty history.

Registry, head and checkpoint files use a JSON envelope `{ "payload": ..., "sha256": ... }`. The checksum covers `VaultFormat.encode(payload)`: sorted-key pretty JSON without slash escaping; dates are Unix seconds including fractions. It detects accidental corruption; it is not an authenticated signature. Objects are named by lower-case SHA-256 of raw bytes. Managed implementations must preserve the same vault/version identities, fields and object bytes; the optional managed reference target is not connected to the app. Compatibility validation remains necessary: the reference transport rejects control characters in names that the local store currently accepts. A local checkpoint is not an unconditional promise of managed upload eligibility.

## Checkpoint capture and publication

A nonblocking OS process lock serializes cooperating Planisphere operations. File traversal is descriptor-relative, rejects symbolic links in roots, ancestors and contents, and refuses sockets, FIFOs and other special files. Existing folder paths are canonicalized; device/inode ancestry also checks aliases when separating store and vault. Case/Unicode-colliding paths are rejected even on case-sensitive disks, so a future copy cannot silently merge them on ordinary macOS filesystems.

The store streams file bytes in 1 MiB chunks to new immutable objects, hashes them, checks file/directory metadata before and after reads, and performs a second full inventory and hash pass. Differences abort publication. Checkpoint manifests are published first, then the head; file and directory synchronization is used at publication boundaries. A crash before head publication may leave unreferenced objects or manifests, which do not become visible history. No automatic deletion or garbage collection is implemented.

This is a validated capture for ordinary concurrent editors, not a filesystem-wide atomic snapshot or a boundary against a hostile process with the same user's unrestricted access. Editing may continue after the captured state. The app does not promise to version every edit. For a known checkpoint, pause external edits and retry if capture reports a change.

Every history read validates the complete published parent chain, metadata checksums, path rules, object sizes and object hashes. Corrupt or missing metadata and objects fail closed; the app does not silently create replacement history. It preserves existing bytes for diagnosis. Verifying all historical objects trades speed for integrity in this first implementation.

## Restore and export

Restore makes a **new** ordinary folder and registers it with a new vault UUID, a first checkpoint and `restoredFrom` linking the original vault/checkpoint. It never restores in place or overwrites newer working files. The destination must not exist and must be outside the store and all registered vaults. A sibling staging folder is built and validated first; exclusive rename refuses a destination that appears before publication, including an empty directory. The original vault and its full history remain unchanged.

Export also requires a new destination. It exports the **latest saved checkpoint** and all published history, including earlier content later changed or deleted. Unsaved working files are excluded. Export does not create a checkpoint and remains available when the original working folder is missing. Create at least one checkpoint before exporting.

```text
<export>/
  files/                         # ordinary latest-saved vault copy
  history/
    export.json                  # envelope: formatVersion, VaultRecord, currentCheckpointID
    checkpoints/<UUID>.json     # every checkpoint in the published parent chain
    objects/<sha256>             # every file object referenced by that chain
```

`files/` opens directly in an ordinary editor. It contains hidden files and empty folders along with notes and attachments. `history/export.json` includes the original local source path as provenance. Complete export is portable without the app's registry, lock file or original source device. Format 1 does not yet provide an import-history UI, although every retained manifest and referenced object is present. A plain-folder import starts a new registered identity; it must not be represented as preserving an exported history chain automatically.

Create/restore folder publication and registry publication span two filesystem locations. If the folder completes but registration fails or the process stops, the completed new folder can remain unregistered, with possible unreferenced history. Add the folder to continue; that starts a new identity if the registration never committed. No partial operation deletes the original or replaces an existing destination. Staging cleanup is best-effort; interrupted staging and orphan objects are retained rather than automatically purged.

## Limits and fidelity

- Up to 250,000 entries per checkpoint; encoded metadata envelopes are limited to 64 MiB before publication. Total byte counts must fit Int64. Available disk space is an additional practical limit; failures preserve already published history.
- Text previews are limited to 512 KiB, valid UTF-8 without NUL bytes. Large or binary attachments remain in history and export.
- Byte content, relative filenames, directory presence and executable status are retained. Exact timestamps, owners, ACLs, extended attributes/resource forks, Finder tags, hard-link relationships and arbitrary permission bits are not retained. Source files are not modified. Restored files use private permissions (0600, or 0700 for executables).
- Filenames must be valid UTF-8, contain no traversal components or backslashes, and be unique under conservative Unicode/case folding. Symlinks and special files require user resolution before checkpointing; the app does not follow or silently omit them.
- This release has no in-place restore, every-keystroke capture, multi-device sync, history garbage collection, automatic backup or remote recovery. An optional managed adapter must establish its own durable storage, access, concurrency and recovery guarantees.

## Verification scope

Storage tests use disposable fixtures only. They cover hidden configuration, binary attachments, empty directories, executable status, changed/deleted content, restart, archive/reactivation, restore origin and original preservation, export without the working folder, corrupt registry/head/object and malformed manifests, path collisions and overflow, symlink/special-file rejection, exclusive destinations, process locking, bounded previews, and injected source changes between complete capture passes. These tests verify local behavior; they are not power-loss, filesystem certification, production security or managed-service validation.
