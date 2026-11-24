# Cloud OAuth and MCP acceptance — 2026-11-24

## Authorized scope

Complete the cloud account connection contract and apply equivalent corrections to GSD and Lorvex. Use synthetic accounts in isolated fixtures; preserve existing accounts, authorization grants, task data, native schemas and the existing private plugin identities.

## Contract

- All existing 22 tools declare their OAuth scopes at the top level and in compatibility metadata.
- Known tool calls with missing, expired or insufficient credentials return an error result carrying `mcp/www_authenticate`; no operation executes. Protected catalog discovery and native APIs remain authenticated.
- Supported MCP versions are negotiated explicitly.
- OAuth issuer metadata agrees with every authorization callback.
- Lorvex consent reaches the existing GSD language and browser-origin standard: Hebrew and English, exact consent scopes, a language-only action that changes neither lifetime nor grant, same-origin forms, localized terminal errors, and persistent selection across a server restart.
- Canonical data, schema version and synchronization algorithms remain unchanged.

## Verification and release

Run the affected Node contract tests plus the existing isolation, persistence and synchronization tests. Keep deployment source snapshots and verify byte identities before rollout. Restart only the existing named application service and verify its public health and auth responses. Revert source files if rollout health fails.

Actual ChatGPT account linking and mobile app availability require a registered App binding and a signed-in owner session. Backend contract checks alone do not establish that acceptance.

## Implemented and verified

- Focused Node regression suite: 27 passed, zero failures. Synthetic fixtures only.
- Missing/expired authorization and insufficient scope reject before tool execution.
- GSD includes expired PocketBase credential reconnect handling and issuer identification on both callback paths.
- Lorvex adds only an OAuth-request language column; migration and restart preserve existing accounts, sessions, consent, PKCE and expiry.
- Source deployment is verified below. Actual personal ChatGPT linking remains a separate acceptance step.

## Production receipt

- Deployed and verified at 2026-11-24T15:34:40Z using the existing lorvex-cloud.service unit.
- Code source: `aa96bad1d8a59ea38b81bdf260788673704e67f8`. Exact live hashes match the tested source.
- Public health returned HTTP 200. Issuer metadata, MCP 2025-11-25 negotiation, authenticated catalog discovery and structured unauthenticated-tool rejection passed.
- Existing unit definitions, environment, account credentials and user data were preserved; only application code modules were copied. Source rollback copies were retained.
- SQLite online backup passed integrity validation before rollout; live integrity validation and the additive language column passed after restart. Rollback restores code only, never a stale database.
- Full public-safety scan passes with the companion image-asset scanner correction. Service template defaults now use documented /srv directories; live units were not reinstalled.
- Registration acceptance remains open: the available owner browser is logged out and the connected Browser extension is unavailable. No App ID was invented; neither private plugin identity nor audience changed.

### Live module hashes

- `server.mjs`: `1fd531b7e1acc17b0a5b1d7d268ee8aad65e55c8e625155a345866000d1b3f3f`
- `store.mjs`: `dd55cb1c151ae5be1b4ef8b914979c29a6076a9b453bea55cd0bfc1ae75bca0b`
- `oauth-page.mjs`: `858f5a6274b3781d8d0da1190fae99d1a01863dc26172de62e9177eba70ce3fc`
