# Optional managed replica publication contract

`PlanisphereManaged` is a separate Swift library. The local `Planisphere` application does not depend on it. Nothing here creates an account, opens a network connection, uploads a user's vault, or enables a managed option in the interface.

This is an executable **in-memory protocol reference**, not a hosted service or durable backup. It defines the minimum publication behavior a later authenticated storage adapter must preserve. An instance starts empty and loses every object, checkpoint and operation receipt on process exit.

## Shared format and API

- `ReplicaScope(tenantID:vaultID:)` names a logical tenant/vault boundary. The reference validates tenant identifier syntax, but does **not authenticate callers**. A future server must derive or authorize the scope against its authenticated identity; accepting a caller's arbitrary tenant ID would not be secure isolation.
- `ReplicaTransport` exposes `uploadObject`, `publish`, `head`, `checkpoint` and `object`, all asynchronous. `InMemoryReplica` is the supplied actor implementation.
- `ReplicaPublication(operationID:expectedParentID:checkpoint:)` carries a shared `PlanisphereCore.Checkpoint` with its shared `FileEntry` values. `VaultFormat.encode/decode` supplies the same format-v1 JSON and fractional Unix-second dates used by the local layer. No independent managed note/checkpoint schema is introduced.
- `ReplicaPublicationReceipt` records the accepted operation, scope, checkpoint/parent IDs and SHA-256 of the shared-format checkpoint bytes. It is an acknowledgment, not a signature, truth claim or evidence of independent remote verification. A returned retry receipt may refer to an older revision after the head advances.

Example publication sequence (all data supplied by the caller):

```swift
let replica: any ReplicaTransport = InMemoryReplica()
let scope = ReplicaScope(tenantID: "example-owner", vaultID: checkpoint.vaultID)
try await replica.uploadObject(bytes, digest: ReplicaDigest.sha256(bytes), in: scope)
let request = ReplicaPublication(expectedParentID: checkpoint.parentID, checkpoint: checkpoint)
let receipt = try await replica.publish(request, in: scope)
```

Upload every file object referenced by a revision before publication. Empty directories are carried in `FileEntry`; empty files still require the SHA-256 object for zero bytes. Reusing an existing scoped object is allowed. Identical bytes stored for one tenant/vault are not automatically visible in another scope.

## Publication invariants

1. Object keys are canonical lowercase 64-character SHA-256. The service recomputes the digest from bytes before storing an upload; a corrupt upload cannot install an object.
2. A format-v1 checkpoint must match the scope's vault ID, name the supplied expected parent, and not name itself as parent. A null expected parent means the scoped head must be empty. This reference accepts a complete first snapshot with a null parent; uploading a local branch with preexisting ancestors requires publishing that chain or an explicitly designed import protocol later. It does not silently discard parent history.
3. Relative POSIX entry paths cannot be empty, absolute, traverse `.`/`..`, contain empty components, backslashes or control characters. Duplicate paths (including canonical Unicode equivalents), and a file used as another entry's parent, are rejected. Directories must have no digest, zero size and no executable flag. Every file needs a valid digest, nonnegative size and an object of exactly that size; total size must not overflow `Int64`.
4. Missing or invalid content rejects the entire revision. No checkpoint, operation receipt or head change becomes visible. Correcting the problem and retrying the unaccepted operation is permitted; previously uploaded objects remain available in that scope.
5. Validation, expected-parent comparison, immutable checkpoint installation, head advancement and operation receipt happen in one actor turn with no suspension points. Concurrent publishers that both expect the same head cannot both advance it. The loser receives `headConflict` and must obtain/reconcile current state explicitly.
6. Accepted operation IDs are scoped and immutable. An identical retry returns the original acknowledgment even after later publications. The same operation ID with different shared-format request bytes fails with `operationConflict`. A checkpoint ID cannot be rebound to a different manifest. No failed publication creates an idempotency reservation.

Path validation here protects manifest structure; it does not write paths to disk or establish safe restoration. Filesystem-specific case folding, reserved names, symlinks, permissions and concurrent editors require the local restore implementation's independent checks. No merge, automatic conflict choice, cloud-to-local write or authority activation is implemented.

## What the reference does not provide

Authentication, authorization, encryption or key custody; network transport; persistent transactional storage; crash recovery; signed receipts; multi-region operation; backup or restore guarantees; retention, deletion or garbage collection; quotas/rate limits; billing; tenant support-access policy; replica synchronization; revocation feeds; and production deployment are all absent. The actor has unbounded in-memory storage and accepts caller-supplied scopes for isolated tests. These limitations prohibit treating it as a production security boundary.

A later durable adapter must persist the manifest, compare-and-swap result and idempotency record in a transaction or equivalent recovery protocol, acknowledge only after the defined durability point, and preserve retries across restarts. Object authorization must be scoped independently of digest knowledge. A request timeout alone cannot prove failure: retry the same operation to learn whether it committed. Retention must preserve every object referenced by retained revisions and define how deletion interacts with retries and history.

## Verification

Run `swift test --filter ReplicaTransportTests`. Contract tests exercise shared-format serialization and binary objects, digest corruption, incomplete revisions and retry, path/size conflicts, cross-tenant/vault isolation, immutable operation/checkpoint identities, and twelve concurrent expected-parent publications with one winner. These are deterministic local contract tests, not evidence of hosted availability, authenticated tenant isolation or durable recovery.
