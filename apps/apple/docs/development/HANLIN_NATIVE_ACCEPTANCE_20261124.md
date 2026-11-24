# Lorvex native acceptance — 24 November 2026

The final simulator build and the two affected native UI cases passed on
[bb05d2ea2303a934a2c968a33a085bd1aebb0e06](https://github.com/davidpovarsky/lorvex/commit/bb05d2ea2303a934a2c968a33a085bd1aebb0e06).
That exact source remains frozen for build **1.0.0 (172)**. This follow-up adds
evidence only; it does not change the source being signed.

The machine-readable [acceptance receipt](HANLIN_NATIVE_ACCEPTANCE_20261124.json)
contains source/tree IDs, product and log hashes, the sanitized run receipts,
screenshot hashes, the exact source comparisons used for reuse, and limitations.
Artifact paths are relative to the build checkout; the main artifact directory is
`apps/apple/dist/native-20261124`.

## Native result

| Scenario | Accepted source | Result |
| --- | --- | --- |
| Official ChatGPT browser → Close → account remains → retry, repeated twice | bb05d2e | PASS, 51.548 s |
| Hebrew assistant, Cloud account, provider and ChatGPT account settings | bb05d2e | PASS, 30.516 s |
| Original composer inside Lorvex | 56123a3, unchanged relevant source and test | PASS, 27.433 s |
| MCP entry opens Cloud account connection | 56123a3, unchanged relevant source and test | PASS, 15.150 s |

The final run completed at **18:04:16 UTC**, exit 0, with a clean checkout.
Four distinct UI scenarios have accepted evidence across two runs. The final run
contains two cases; it is not reported as a fresh four-case run.

The compiler was Xcode 27.1 / Swift 6.4. The runtime driver was Xcode 27.0 against
the installed iOS 27.2 runtime build 24B8117, using the exact compiler-produced
arm64 `.xctestrun`. Runtime invocation does not load the project or resolve
packages. The runner keeps assertions, complete result bundles, logs and explicit
screenshots while disabling the automatic system-wide diagnostics collection
with the supported `-collect-test-diagnostics never` option. Build parallelism
was bounded to three jobs.

The final compiled simulator app reports bundle `com.itorah.lorvex`, version
1.0.0, build 172 and minimum iOS 27.0. Its executable SHA-256 is
`7062e8b673cb8ae1a30eeedb9f9d3d2f17d8aca176ad82aaf0396696ebc93e6c`.
The selected test manifest SHA-256 is
`d70184389f4313a8673655bfdbfb16d9d7fbde8928571e131a29aefa4da80eb0`.

## What the final UI repair changed

The earlier runtime hierarchy showed that an accessibility identifier attached
to a native Form section propagated onto the actual Continue button. Moving that
identifier to the section header restored the button's own stable identifier and
hittability without replacing native row behavior.

The remaining cancellation failure was a presentation ownership problem. The
account view embedded Safari in a SwiftUI sheet, then cleared the sheet binding
inside Safari's native Close callback. Safari performs its own dismissal after
that callback. Apple's API requires presenting Safari modally through
`UIViewController.present`, and its delegate contract describes that subsequent
native dismissal. The final implementation uses a stable UIKit presenter and
retains only its owned Safari controller. Native Close fences the matching
authorization attempt without issuing another dismissal. Callback/timeout
dismissal targets only that browser, with identity-guarded completion. Queued
retry state remains available during transitions.

The actual native cancellation test now verifies the whole product path twice:
the browser opens, its Close button is tapped, the account screen remains,
“Sign-in cancelled” is displayed, and the real Continue control remains enabled
and hittable for another browser launch. Provider/model preparation also runs
once per settings presentation, preserving the in-progress draft.

The Close selector is scoped to the browser and asserts the exact identifier
`Close`; the outer assistant close control has identifier `hanlin.close`.
The observed native Close frame was (10, 35, 44, 44), and both cancellation cycles
retained the account screen. The optional sanitized snapshot ancestry helper
returned two empty text attachments under this driver. Those empty attachments
are explicitly excluded as ancestry evidence.

API references:

- [SFSafariViewController presentation contract](https://developer.apple.com/documentation/safariservices/sfsafariviewcontroller)
- [Safari Close delegate contract](https://developer.apple.com/documentation/safariservices/sfsafariviewcontrollerdelegate/safariviewcontrollerdidfinish(_:))

## Background lifecycle parity

The shared review found three concrete background ownership gaps. The integrated
fix retains and cancels the owned flush task, blocks a late autosave continuation
from starting a new sync phase after expiration, checks cancellation between
refresh phases, and checks current foreground state before suspending a database
from a late expiry callback. Completed autosave work remains intact. SwiftUI
continues to own its background-task completion.

Nine actual-source deterministic scenarios passed, using real Swift Tasks with
stub UIKit/database/store endpoints. Restoring the three bugs produced six
expected failures, demonstrating sensitivity to the reported regressions.
Four existing native lifecycle wiring tests also passed. The final iOS build
compiled all three changed production lifecycle files.

## Earlier evidence and exact reuse

| Gate | Accepted result | Source |
| --- | --- | --- |
| Canonical Plan, agent and presentation state | 17 passed | 93a399b |
| Cloud account synchronization | 10 passed | 93a399b |
| Distribution metadata | 3 passed | d37dff0 |
| Full static baseline | 877 passed | d37dff0 |
| Background lifecycle wiring | 4 passed | 56123a3 |
| Background lifecycle deterministic probe | 9 passed | 56123a3 |

The combined earlier Cloud/metadata invocation had one outdated metadata
expectation. Its Cloud suite passed; the corrected three metadata cases passed
in their separate rerun. The original mixed invocation is not described as an
overall success.

Source comparison to bb05 verified identical Hanlin production/test trees,
package manifest, package lock and SDK lock. The Cloud comparison verified the
entire Mobile and core-package trees, its test file, and all 548 Core Swift source
files. Metadata and lifecycle production/test inputs also match their accepted
sources. Composer/MCP test methods and shared helpers have identical SHA-256
hashes, as do the relevant assistant, workspace, composer and Cloud source
objects. The JSON records those Git object IDs and method hashes.

The 877-case result remains a baseline result, not a claim of a full rerun on
bb05. Later changes received their affected acknowledgment/resource checks,
Swift parsing, public-safety checks, deterministic lifecycle cases, native wiring
tests and actual iOS/UI build/runtime validation. Hebrew settings was rerun
because the presenter anchor changed that hierarchy.

The pinned Hanlin SDK is
`bea35c3c2a435d1cc5f7ce93b08a649b104bc10f`; the direct swift-ai-sdk dependency
matches `07431abccbfb151ca2dab67bca6cf86fcb2bd3b8`. Acknowledgments include
18 external locked packages plus the local Hanlin MIT license, Swift-JSON
Apache license and RhoeJSON notice. Generation, drift rejection and source
notice inclusion were verified.

## Visual review and prior failures

Five fresh non-authentication frames were actually inspected: Hebrew assistant,
provider settings, Cloud account and ChatGPT account, plus the English account
after cancellation. The account frames received an independent second reviewer.
No visible overlap, unreadable copy, unintended text clipping or RTL defect was
observed. The Cloud Form continues below its native viewport. Screenshot hashes
and observations are recorded in the JSON. Native UI assertions, rather than
screenshots alone, establish actual button hittability and cancellation/retry.

The initial four-case UI run had two failures. After the accessibility fix, three
cases passed and cancellation remained failing. One-time settings preparation
alone did not solve the remaining failure; the owned UIKit presenter did.
Those failed runs remain recorded.

The long exit after the earlier ffd run was traced to automatic
`simctl diagnose --timeout=600` after test assertions had finished. An earlier
package-loading deadlock explanation was not established and is corrected.
Only the owned diagnostic child was stopped; the parent then completed with
exit 65 and a complete result bundle. The final run exited normally.

## Release handoff and limits

The release owner is archiving and delivering the exact frozen bb05 source as
build 172. Archive/export, recursive Mach-O and IPA audits, Apple validation,
upload and TestFlight processing are separate release evidence. This document
does not assert their completion.

The native tests used a fresh owned iPad simulator. They opened the real official
pre-consent authorization browser but did not grant a personal account, exchange
personal credentials or complete subscribed inference. No physical-iPad
acceptance is claimed. Background probes establish ownership/phase boundaries;
they do not claim a real OS expiration event or rollback of sync already running.
No private authorization page screenshots, tokens or credentials are included.
