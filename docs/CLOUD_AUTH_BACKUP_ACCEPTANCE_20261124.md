# Lorvex Cloud authentication and backup acceptance — 2026-11-24

The canonical-account throttle repair is live from [`351add8c85129ebc34e4d6df868e0088797fe341`](https://github.com/davidpovarsky/lorvex/commit/351add8c85129ebc34e4d6df868e0088797fe341). The exact published tree is `a81d13d2bdd6485a553604024ce90dd7e3ef4a18`. This server change leaves the signed iOS 1.0.0 (172) source `bb05d2ea2303a934a2c968a33a085bd1aebb0e06` unchanged.

## Reproduced defect and repair

Authentication already lowercased and trimmed account email addresses. Attempt buckets lowercased a truncated prefix, which let equivalent addresses with surrounding whitespace enter different buckets and caused distinct long accounts with a common prefix to share a bucket. The same final ten real HTTP regression tests produced five failures on the exact deployed baseline and all passed on the repair.

All four REST/OAuth login/registration paths now use the store's complete canonical normalization, followed by SHA-256. The fixed-size digest preserves identity without retaining oversized invalid input in the attempt map. Existing authentication validation, opaque errors, thresholds and ten-minute cooldown remain unchanged.

## Focused verification

The isolated Node 24.22.0 run passed **27/27 tests**: ten limiter cases, one populated backup/restore case, and sixteen affected authentication, OAuth localization and MCP contracts. The tests exercise real HTTP requests, failed-attempt accumulation, cooldown before and after the boundary, REST/OAuth bucket sharing, independent accounts, canonical aliases, distinct long identities, and 128 KiB invalid input. Time advances only through the isolated server's injected clock.

The fixed log SHA-256 is `d9f8167d211eb40b007a558e7b33c566085aba30ac302545039932a840c580ea`. The identical final limiter test suite's baseline log SHA-256 is `28ff1a1d14baa69a6ae0ce9e25010306da3c2050c41d52a00f1805a22dcd3526`.

From `cloud`:

```sh
node --test --test-concurrency=1 --test-reporter=tap rate-limit.test.mjs backup.test.mjs server.test.mjs oauth-contract.test.mjs oauth-localization.test.mjs mcp-auth.test.mjs
```

## Populated online backup and restore

The **actual deployed backup.py** backed up an isolated SQLite fixture while its original connection remained open with committed WAL. The fixture held two accounts, two task entities, two changes, two idempotency receipts, two sessions and two audit records. The gzip had mode 0600 and was 3,059 bytes; the restored database was 86,016 bytes.

Restoration passed SQLite integrity checking and preserved the complete logical database digest, including schema and every table row: `03d5874499b206da2f389085a0d223a0cab27aec2f0c47f1ce1ba62c4df5aa64`. The archive digest was `32a67ae6735d60f85b71474d457d590cc6dca273cfd257d6fb32548bb628fcbd`. Preserved sessions authenticated against the restored server, each account saw only its own task, and replaying both saved request IDs returned the original task IDs without changing the logical database. All synthetic data was removed after the test.

This closes the populated-fixture proof gap left by earlier empty-database restore receipts. It is an isolated restore, not a restore into the live service. The exact deployed script hash and complete receipt are in the accompanying [JSON evidence](evidence/cloud-auth-backup-20261124/acceptance.json).

## Production readback

At **19:39:35 UTC**, only the two reviewed server modules were replaced, with protected rollback copies, preserved ownership/mode, staged syntax checks and one successful service restart. Public health returned 200; issuer identification, MCP protocol 2025-11-25, protected catalog 401 and the unauthenticated `invalid_token` linking challenge passed. The active service's module hashes matched the published tested bytes. No production account authentication attempts, database edits, configuration changes or limit overrides were made.

An earlier syntax preflight rejected the temporary file extension before any live replacement. Correcting the temporary suffix resolved that staging issue. No rollback was needed for the verified deployment.

## Remaining personal acceptance

This evidence does not establish the user's ChatGPT Cloud consent, physical-device installation/migration, personal offline/background sync roundtrip or first subscribed-model reply. The existing exposed links' legacy device-offline response does not establish Cloud acceptance. Cloud01 and OAuth03 retain their recorded personal migration/consent criteria; this report proves the server-side submilestone.
