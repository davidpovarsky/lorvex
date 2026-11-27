# Native sync handoff: legacy write receipts

Server lane: `fix/lorvex-cloud-integration-20261127` (base
`a16ab56d8507f6e02ba0b10d4b099c735f38da66`). Final tested revision is recorded in
the integration handoff receipt. No change is made to the native 120-tool catalog
or the canonical schema manifests.

## Exact HTTP response

`POST /cloud/v1/sync/push` with a previously stored receipt that has no verifiable
request digest returns HTTP **409**, `Content-Type: application/json`:

```json
{"error":"idempotency_reconciliation_required"}
```

A receipt with a proven checksum mismatch returns HTTP **409**:

```json
{"error":"idempotency_conflict"}
```

The current `server.mjs` already serializes `CloudError.status` and
`CloudError.code` this way; no special HTTP mapping is required. MCP tool calls
use HTTP 200 JSON-RPC with `result.isError: true` and the same code in the text
content. Neither error authorizes automatic repetition under a fresh ID.

## Committed legacy uploads

Pre-upgrade sync receipts contain `results`. An accepted item includes its
immutable `seq`. The server reads that exact `changes` row under the authenticated
`account_id` and compares all seven wire fields against the submitted envelope:

`entity_type`, `entity_id`, `operation`, `version`, `payload_schema_version`,
`payload`, and `device_id`.

When every item matches, the server upgrades that receipt with the request
checksum and returns the saved original successful response. It performs no new
entity mutation and does not advance the account change cursor. This preserves
normal retries of committed uploads after a service update, even when later
edits have changed the current entity value.

Legacy results that only say `duplicate`, have stale winners, or do not bind
every input to a historical accepted sequence cannot establish the original
intent. They remain intact and return reconciliation-required. They are never
deleted or silently treated as new.

## Client recovery proof

`GET /cloud/v1/sync/changes?cursor=<cursor>&limit=<1..200>` returns:

```json
{
  "envelopes": [{
    "entity_type": "task",
    "entity_id": "task-uuid",
    "operation": "upsert",
    "version": "1795737600000_0000_0123456789abcdef",
    "payload_schema_version": 4,
    "payload": "{...canonical serialized payload...}",
    "device_id": "origin-device"
  }],
  "cursor": 123,
  "has_more": false
}
```

The bearer token fixes the account. Pages contain historical accepted envelopes,
not just the latest value. An outbox mutation is proven committed only by an
exact matching envelope, including operation and version. A task with the same
title or last-value equality is insufficient. To recover an older pending batch
whose evidence predates the locally saved cursor, inspect the required retained
history (cursor 0 when there is no narrower verified checkpoint), continuing
until `has_more` is false. Do not reset or mix another account's cursor.

Acknowledge only the specifically proven committed outbox entries. For remaining
entries, follow the existing merge/CAS workflow against current server versions
and mint a new request ID only for the reconciled new batch. Preserve the
original queue on incomplete reads or errors. Stop an endless retry of the same
409 response without discarding user changes.

## Focused regressions

`cloud/operations.test.mjs` covers:

- A committed legacy upload upgraded by its immutable change sequence, with an
  unchanged cursor and no duplicate mutation.
- An unverifiable legacy receipt returning reconciliation-required without
  changing any entity or cursor.
- Request checksum mismatches across sync batches and MCP tools.
- Same request IDs isolated between accounts.

The native sync owner must separately prove the queued-write recovery behavior
on its final source revision. The server lane does not claim native UI or sync
acceptance from these Node tests.
