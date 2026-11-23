# Canonical Lorvex lifecycle helper

This Linux process executes the same Swift domain, SQLite store, workflow and
sync implementation used by the Apple app. Source directories and SQL resources
are symbolic links to their canonical repository paths. It creates an **in-memory**
store for one isolated account snapshot, applies the canonical envelopes, runs
the canonical lifecycle operation and returns the complete canonical outbox.
It never opens the cloud database or creates a persistent application database.

The Node cloud adapter owns OAuth/account authorization, request receipts, audit,
and committing the returned envelopes. It must verify the captured account
revision under its write transaction and commit the entire returned outbox or
nothing. A concurrent account mutation requires a fresh snapshot and retry.

## Process protocol

Read one JSON object from stdin, then exit after one JSON response on stdout:

```json
{
  "envelopes": [],
  "action": "complete_task",
  "arguments": {"id": "019ad4b2-0000-7000-8000-000000000001"},
  "device_id": "lorvex-cloud-server",
  "now": "2026-11-23T12:00:00Z",
  "timezone": "Asia/Jerusalem"
}
```

`envelopes` must contain the complete account snapshot, including current
tombstones. Incomplete references, duplicate identities, malformed payloads,
future unsupported schemas and unresolved canonical invariants fail closed.
Supported actions are `complete_task`, `cancel_task`, `reopen_task`,
`start_task` and `pause_task`. Cancellation means skip the current occurrence,
matching the app's ordinary cancellation action.

`now` is optional (UTC wall time by default). `timezone` is an optional
account timezone fallback used only when the snapshot contains no canonical
timezone preference. The fallback is never returned as a preference mutation.

The response has `envelopes`, `result.task` and `changed`. Every returned
envelope uses the canonical schema and HLC. The result task is the full canonical
payload. No credentials, account identifiers or device-local AI audit entries
are required in this process. A rejected operation exits nonzero without
publishing partial output. The command enforces a 32 MiB input/output limit;
the server additionally enforces a deadline and output cap.

## Build, verify and package

Requires a Linux Swift 6 toolchain and system SQLite development headers.
Dependencies are pinned by `Package.resolved`. Apple's official
`swift-crypto` supplies the CryptoKit API for unchanged canonical store sources.
The canonical platform adaptations are a Linux UTF-16 CoreFoundation bridge
in `LorvexDomain/Tag.swift` (the same case-folding algorithm), and disabling
the optional NSMapTable streak cache on Linux while retaining its exact
calculation. Both Darwin implementations remain unchanged.

```sh
python3 cloud/native/build.py --jobs 2
```

Use `--scratch-path` and `--cache-path` on machines with constrained durable
storage, for example a dedicated tmpfs directory. The build script runs the
focused native contract tests, packages the executable with adjacent SwiftPM
resource directories, and records source/dependency hashes in
`cloud/native/dist/source-manifest.json`.

Deploy the complete contents of `dist` together, then configure:

```text
LORVEX_CANONICAL_CORE_EXECUTABLE=/mnt/development/services/lorvex-cloud/native/lorvex-cloud-native
```

The runtime requires the Swift shared libraries provided by the matching
toolchain and SQLite; verify with `ldd` on the target. Do not deploy only the
binary while omitting its resources.

The focused tests cover full completion fan-out, wire serialization, deterministic
successor identity, replay without duplicates, reopen and re-completion, exhausted
COUNT, skip cancellation, account timezone, advanced-successor protection, invalid
snapshots and Unicode normalization. The Node adapter has separate tests for
atomic persistence, account revision conflicts and process limits.
