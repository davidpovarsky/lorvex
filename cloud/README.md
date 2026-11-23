# Lorvex Cloud — account-first backend

This is the new account-scoped server. It runs in a *separate process* from the
original device pairing bridge, and stores Lorvex data centrally on the user's
Oracle server. The old bridge continues to serve legacy clients unchanged.

## Storage and protocol

- Node.js 24+ built-in node:sqlite, WAL mode, with account-isolated primary
  keys for sync entities, durable change log and idempotency receipts.
- OAuth 2.1 authorization-code PKCE + dynamic client registration for ChatGPT.
  A normal Lorvex email/password account login replaces the device pairing
  code. Passwords use scrypt salted verifiers; access and refresh tokens are
  stored only as hashes and refresh tokens rotate on use.
- REST endpoints: /cloud/v1/auth/register, login, refresh, logout;
  /cloud/v1/account/me, /cloud/v1/sync/changes and /cloud/v1/sync/push.
- Streamable HTTP MCP: /cloud/mcp with 22 tools, server-side execution even
  while the iPad is off. Normal writes are consented to via the OAuth scope,
  not each individual iPad confirmation. Destructive decisions can still be
  governed by ChatGPT's own authorization.
- SyncEnvelope wire format is shared with LorvexSync: entity_type,
  entity_id, operation, HLC version, payload_schema_version, payload JSON
  string, and device_id. Native output retains its declared canonical schema
  (current task lifecycle output uses v3; server-created payloads use v4).
  The client reconciles server winners using the
  native Lorvex sync engine (not an alternate task engine).
- First account use requires an explicit local data migration/sync on iPad;
  existing device data and legacy paired credentials are NOT silently
  reassigned or overwritten.

## Deploy

Run `node --test cloud/*.test.mjs` before rollout.
Copy the canonical `schema/sync_payload/004.json` to the runtime directory as
`sync-payload-004.json` (or point LORVEX_CLOUD_CONTRACT_PATH at it).
Copy canonical.mjs, payload.mjs, store.mjs, tools.mjs and server.mjs into
/home/ubuntu/lorvex-cloud, install lorvex-cloud.service with systemd,
and mount the public /cloud prefix through the existing localhost Lorvex MCP
relay on port 8767. The new service itself listens only at 127.0.0.1:8769.

Production URL (Oracle/Tailscale Funnel):
  https://torah-social.tail0a6c7d.ts.net:10000/cloud

Custom MCP URL:
  https://torah-social.tail0a6c7d.ts.net:10000/cloud/mcp

WARNING: The initial signup flow is self-service, so only add real data after
the user creates their account. Never use sample credentials outside tests.
The production SQLite data and snapshots live under
/mnt/development/services/lorvex-cloud/{data,backups}. Both units require the
mounted volume and restrict writes to their respective directory. Create these
directories as ubuntu with mode 0700 before installing the units. When moving an
existing database, stop the writer, use SQLite online backup, compare integrity
and table counts, copy/verify backups, and retain the originals for rollback
before changing LORVEX_CLOUD_DB and LORVEX_CLOUD_BACKUP_DIR. After writes resume,
a rollback must first copy and verify the latest database back to the old
location; never reactivate the retained, now-stale pre-migration copy. Never raw-copy a live
WAL database. This separates service persistence from the root filesystem but
does not resolve host-wide free-space pressure; monitor both volumes.
Daily online-safe SQLite snapshots use backup.py and the backup timer.
At-rest backups must be protected like user data and never committed.

## Canonical recurring task transitions

When configured, all five task lifecycle actions (ordinary and recurring) invoke the shared Swift Core
through cloud/native. Set LORVEX_CANONICAL_CORE_EXECUTABLE to the deployed
lorvex-cloud-native binary and keep its Swift resource bundles adjacent. After
installing and verifying the native bundle, install lorvex-cloud-canonical.conf
as /etc/systemd/system/lorvex-cloud.service.d/canonical.conf and reload/restart
the service. Each
request hydrates an ephemeral in-memory database from the account snapshot,
runs existing lifecycle and recurrence operations, and returns canonical outbox
envelopes. The Node service compares the account change cursor before committing
all emitted entities, audit and idempotency receipt in one transaction; up to
three bounded attempts preserve concurrent edits. No other persistent store or
recurrence implementation is introduced. Failed native execution leaves data unchanged. Without a configured native
executable, ordinary actions retain the prior basic fallback and recurring
actions fail closed; production configures the helper to preserve all canonical
reminder, dependency and recurrence sideeffects. Process execution is limited to 15 seconds and 32 MiB
of input/output, with a maximum 50,000 snapshot entities. The stored account
timezone is passed as the fallback for the native preference snapshot.

get_today and omitted-date list_habits use the canonical timezone preference
(entity type preference, id/key timezone), with accounts.timezone as the fallback.
Reading the effective zone does not rewrite account settings. Habit completion
writes require an explicit local civil date.

## Test limits

All integrations and data models require native iPad tests against the real
Lorvex Core before broad release. A successful synthetic MCP round-trip is
not proof of native SyncEnvelope semantic convergence, and the user still
must sign in and migrate their data. The cloud account endpoint does not grant
a ChatGPT account plan by itself; that requires the separately documented
OpenAI Sign in with ChatGPT flow and user eligibility.
