# Cloud task operations and retry contract

The cloud MCP catalog contains 26 tools. The existing 22 tools retain their
names and parameters. The new tools are `list_dependencies`, `add_dependency`,
`remove_dependency`, and `delete_task`. Task responses add `depends_on`, an
array of prerequisite task IDs. The native app's 120-tool host catalog is
unchanged.

Dependency mutations run the existing Swift `TaskUpdate` preparation, mutation
and cycle validation. The helper emits the canonical task and edge outbox
payloads, including tombstones for removed edges. Canonical tombstones retain
the deleted row's historical snapshot version while their envelope contains the
new deletion version. The process adapter preserves this contract and rejects
future snapshots; upserts require matching payload and envelope versions.
An unknown, foreign, archived
or cancelled prerequisite is rejected by the account boundary or native domain
rules. Node does not implement a second dependency engine.

`delete_task` moves the task to Trash using the same `TaskArchive.archiveTaskOp`
as the app. It preserves the task and related data for recovery. It does not
invoke permanent deletion or bypass the canonical two-step Trash guard. Normal
list, search, dashboard and Today views exclude archived tasks; exact-ID reads
retain the rich archived object. Restore remains the app's existing canonical
restore operation, covered by the helper acceptance test.

Every write accepts `request_id`. Request IDs are scoped to the authenticated
account and bind the complete tool name and arguments with a canonical checksum.
Identical retries return the saved result; a different payload, tool, endpoint
pair or sync batch returns `idempotency_conflict`. A receipt from before this
change does not contain a checksum. Legacy sync receipts whose accepted results
carry immutable change sequence numbers are upgraded only after every submitted
wire envelope exactly matches those account-scoped historical changes. This
allows already committed outbox uploads to retry without another mutation.
Other unverifiable legacy receipts return HTTP 409
`idempotency_reconciliation_required`; the original receipt is retained. This
is distinct from a proven checksum mismatch (`idempotency_conflict`).

A client receiving reconciliation-required must pull the account's current
changes and acknowledge only outbox entries whose exact desired mutation is
already represented. Otherwise it must reconcile against current versions and
submit a new intent with a new request ID and correct CAS expectations. It must
not discard queued writes, silently repeat a possibly committed mutation, or
retry the same rejected ID forever. Compatibility acceptance must verify this
recovery in the native sync owner before deployment. Existing authorization
grants require no reconnection. Public successful sync response schemas remain
unchanged.

Ordinary writes, related entities, audit events and the final receipt commit in
one SQLite `BEGIN IMMEDIATE` transaction. Canonical Swift operations run on an
account-only snapshot; their envelopes, audit event and receipt commit in one
transaction after checking that the snapshot has not changed. Contention retries
are bounded, and any stale emitted entity rolls back the entire operation. The
complete returned task, including tags and dependencies, is frozen in its
receipt. Cloud audit entries remain durable and account scoped. The native
helper's `ai_changelog` is device local and never enters the sync stream.

The helper package links the existing native core sources and schema. They are
not modified. Deployment must ship the verified helper binary and its matching
resource bundles together with `tools.mjs`, `store.mjs`, `canonical.mjs`,
`request-fingerprint.mjs`, and `task-result.mjs`. Existing OAuth and old device
bridge URLs remain active. Back up and verify the cloud SQLite database before
replacing the service bundle.

## Acceptance commands

Run `node --test cloud/*.test.mjs` for the HTTP, OAuth, storage, account isolation,
transaction, receipt and adapter regressions. Build and test the real canonical
helper with `python3 cloud/native/build.py --jobs 3` (isolated scratch and cache
paths are recommended on the shared runner). Then run
`node cloud/live-acceptance.mjs /path/to/new-receipt.json` from the repository
root. This last command uses a private temporary SQLite database, normal account
OAuth/PKCE and the packaged Swift executable, including dependency tombstones,
recoverable deletion, refresh/revocation and restart replay. It cleans up its
database and synthetic accounts. Receipts include source and binary hashes.

These cloud checks do not replace native app regression 902, MCP host 120,
physical-device synchronization or a live ChatGPT conversation. Their final
app-source evidence is owned by the native application lane.
