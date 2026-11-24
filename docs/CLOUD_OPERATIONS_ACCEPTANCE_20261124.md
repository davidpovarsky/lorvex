# Lorvex Cloud operations readback — 24 November 2026

This bounded verification updates the old Cloud01 capacity and telemetry notes.
It changes no service, configuration, production account, or application source.
The machine-readable receipt is `evidence/cloud-operations-20261124/operations-readback.json`.

## Observed capacity and service continuity

At **2026-11-24T16:23:19.465681+00:00**, root had **1,063,915,520 bytes** available
(1014.629 MiB), and the data mount had
**5,204,611,072 bytes** available
(4963.504 MiB).
Both exceeded the previously coordinated shared-host admission comparisons:
768 MiB for root and 512 MiB for data. The old 384–386 MiB root observation is
not the current measurement. This is a timestamped observation, not reserved
capacity or a promise about future writers.

Lorvex Cloud and the retained legacy MCP bridge were active and enabled.
No restart was performed. The live cloud server SHA-256 remained
`1fd531b7e1acc17b0a5b1d7d268ee8aad65e55c8e625155a345866000d1b3f3f`, matching the accepted authentication deployment.
The public Lorvex and GSD health endpoints both returned HTTP 200. These are
liveness responses; they do not prove a personal account workflow.

## Scheduled backup receipt

The installed timer actually triggered on **24 November at 03:31:45 UTC**;
the backup service exited successfully with status 0. The timer remained
active/enabled, with its then-observed next trigger at **25 November 03:22:53 UTC**.

The produced archive was `lorvex-cloud-20261124T033145Z.sqlite.gz`:
2489 compressed bytes, SHA-256
`109cdac2d3f4cee683cecd922107a8e560e750bf282a007c7eed3a030d89d8a6`.
It decoded to 159744 bytes with gzip CRC validation.
The exact snapshot was opened read-only with SQLite query-only mode;
`PRAGMA integrity_check` returned `ok`. Bytes were unchanged and the isolated
mode-0700 temporary directory and mode-0600 snapshot were removed.
No account rows or user content were inspected or exported.

An initial in-memory deserialize probe could not open the WAL-format snapshot.
This is retained in the receipt. The subsequent file-backed verifier used the
same unchanged snapshot bytes and read-only immutable opening; it passed.
No live database was restored or replaced.

## Operational telemetry actually verified

Existing `cloud/server.mjs` emits OAuth method, path and HTTP status after
response completion, without the URL query or body. One intentionally invalid
GET to `/cloud/oauth/authorize` returned 400 before `beginOAuth`; the exact
`OAUTH_AUDIT GET /cloud/oauth/authorize 400` event appeared in the service journal.
No account, token, grant or authorization-request row was created.

The source also logs server errors and writes per-account mutation audit records
in the same transaction as entity changes. Previous cloud fixtures cover that
mutation path; this readback did not create another write fixture.
The receipt exports only allowlisted aggregate/status metadata. It does not
export journal message bodies or database content.

Basic service health, OAuth event observability, successful scheduled backup,
and recoverable backup structure are now evidenced. This does not assert
centralized dashboards, resource alerts or a service-level objective.

## Remaining task acceptance

The current backend readback does not replace a real Lorvex account migration,
physical iPad/cloud convergence, offline recovery, or personal ChatGPT Connect.
Cloud01 stays open for the remaining product acceptance. Earlier deployment and
backup evidence stays historical; no completed task or personal result is inferred.
