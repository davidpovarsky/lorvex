# Lorvex signed release acceptance — 24 November 2026

**Lorvex 1.0.0 (172) passed archive/export, recursive bundle verification, Apple validation, upload and processing. Apple reports `VALID`, and the existing internal TestFlight group has access with state `IN_BETA_TESTING`.**

The signed release uses frozen source
[bb05d2ea2303a934a2c968a33a085bd1aebb0e06](https://github.com/davidpovarsky/lorvex/commit/bb05d2ea2303a934a2c968a33a085bd1aebb0e06),
tree `36c14a4b99dda155d98d7007bef261bdb7f0c9b6`, with Hanlin SDK
`bea35c3c2a435d1cc5f7ce93b08a649b104bc10f`. This publication adds two evidence
files on top of documentation revision `bb456ec3bd90a357cf2a302361540393cab76863`;
it does not change the application, release scripts, or frozen Mac checkout.

The [machine-readable receipt](HANLIN_RELEASE_ACCEPTANCE_20261124.json) records
allowlisted results, timestamps and source-receipt hashes. The earlier
[native acceptance](HANLIN_NATIVE_ACCEPTANCE_20261124.md) covers the actual
simulator/UI work and exact reuse of earlier tests. This release receipt updates
the release status that was still in progress when that earlier evidence was written.

## Release result

| Gate | Observed result |
| --- | --- |
| Archive and export | Both succeeded; the validation phase exited 0 at 18:20:17 UTC. |
| Recursive bundle audit | `LorvexMobileApp.app` passed the recursive iOS payload verifier. |
| Apple validation | Reported `No errors validating archive`. |
| Delivery | Upload phase exited 0 at 18:22:04 UTC. |
| Apple processing | `VALID`, not expired, verified at 18:31:21 UTC. |
| Existing internal TestFlight group | Build relationship confirmed; `IN_BETA_TESTING`. No group relationship was added and no new invitations were sent. |

Apple build ID: `e5c310ef-ce91-45cd-b107-0e6c62e2483c`.
The external beta state is `READY_FOR_BETA_SUBMISSION`; this receipt does not
claim external beta approval or public availability.

An initial ancillary API request to inspect the TestFlight group relationship
returned HTTP 403. Verification subsequently succeeded through the official
`betaGroups/{id}/relationships/builds` route. That was a recovered group
verification issue; the archive, validation and upload had already succeeded.

## Exact delivery artifact

| Field | Value |
| --- | --- |
| Delivery filename | `Lorvex-1.0.0-172.ipa` |
| Original export filename | `LorvexMobileApp.ipa` |
| Size | 88,841,687 bytes |
| SHA-256 | `d9ff7181779ca0588bb737c374eecaaf32a620f2e6e1f005ee3054114b383de1` |

The copied delivery file has the same complete size and SHA-256 as the validated
export. Whole-file verification passed at the intermediate copy and after final
assembly, followed by an independent final hash read. No binary is included in
this public documentation update.

## Acceptance limits

Physical-device installation and launch of this signed build remain unverified.
A personal Cloud OAuth grant, personal ChatGPT authorization/token exchange and
subscribed inference also remain unverified. The native UI evidence establishes
opening the official pre-consent browser, cancelling and retrying while retaining
the account screen; it does not establish a completed personal grant.

The two exposed legacy device links currently report offline. Those results
provide no Cloud acceptance evidence. Internal TestFlight availability is a
verified distribution milestone, while those device and personal-account checks
remain open.

Only allowlisted release facts and hashes are published here. The documents
exclude key material, account identities, raw machine paths, private file links,
authorization logs and release binaries.
