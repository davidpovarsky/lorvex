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
  entity_id, operation, HLC version, payload_schema_version=4, payload JSON
  string, and device_id. The client reconciles server winners using the
  native Lorvex sync engine (not an alternate task engine).
- First account use requires an explicit local data migration/sync on iPad;
  existing device data and legacy paired credentials are NOT silently
  reassigned or overwritten.

## Deploy

Run node --test cloud/server.test.mjs before rollout.
Copy store.mjs, tools.mjs and server.mjs into
/home/ubuntu/lorvex-cloud, install lorvex-cloud.service with systemd,
and mount the public /cloud prefix through the existing localhost Lorvex MCP
relay on port 8767. The new service itself listens only at 127.0.0.1:8769.

Production URL (Oracle/Tailscale Funnel):
  https://torah-social.tail0a6c7d.ts.net:10000/cloud

Custom MCP URL:
  https://torah-social.tail0a6c7d.ts.net:10000/cloud/mcp

WARNING: The initial signup flow is self-service, so only add real data after
the user creates their account. Never use sample credentials outside tests.
Daily online-safe SQLite snapshots use backup.py and the backup timer.
At-rest backups must be protected like user data and never committed.

## Test limits

All integrations and data models require native iPad tests against the real
Lorvex Core before broad release. A successful synthetic MCP round-trip is
not proof of native SyncEnvelope semantic convergence, and the user still
must sign in and migrate their data. The cloud account endpoint does not grant
a ChatGPT account plan by itself; that requires the separately documented
OpenAI Sign in with ChatGPT flow and user eligibility.
