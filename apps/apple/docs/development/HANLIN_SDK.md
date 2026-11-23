# Canonical Hanlin SDK in Lorvex

Lorvex installs one immutable Hanlin SDK revision from `HanlinSDK.lock.json`. The
old `apps/apple/Vendor/HanlinAgentSDK` and `HanlinPlatform` source forks are removed.
`Vendor/HanlinSDK` is an ignored, installer-owned canonical checkout; shared source
changes belong in `davidpovarsky/hanlin-ai`, then Lorvex advances its lock revision.

## Setup and upgrades

From the repository root, with the Apple toolchain installed:

```sh
python3 apps/apple/script/install_hanlin_sdk.py
python3 apps/apple/script/install_hanlin_sdk.py --check
```

The small host bootstrap retrieves `Scripts/SDK/install.py` from the exact full
commit revision in the lock. The canonical installer generates the selected
product manifest in place and retains original target source paths. Its sparse
checkout materializes only that closure; this consumer downloads no Node/Python
runtime or unrelated application source. It refuses to overwrite source edits.
An optional `--source-cache /path/to/canonical/hanlin` reuses local Git objects.
The cache must remain available for such a shared checkout.

To upgrade, change the full revision in `HanlinSDK.lock.json`, run installation,
and validate the changed host surfaces. Both SwiftPM and XcodeGen resolve the
same package at the repository-root `Vendor/HanlinSDK`; neither retains a second
SDK implementation. The generated package and installation receipt are not
committed to Lorvex.

## Ownership

| Surface | Canonical owner | Lorvex supplies |
| --- | --- | --- |
| Agent loop, provider streaming, dispatch/persistence | HanlinAgentCore, HanlinChatCore, HanlinPersistenceAdapters | Actual Core service, scoped 22-tool catalog, write authorizer, refresh callback |
| Chat layout | HanlinChatUI `HanlinChatView` | Current conversation, host chart, placement |
| User/assistant bubbles | `HanlinUserMessageBubble`, `HanlinAssistantMessageBubble` | Text and original host actions |
| Streaming Markdown | `HanlinMarkdownView` | Observed response/reasoning text |
| Composer | `HanlinMorphComposer`, `NativeMultilineTextEditor`, shared geometry | Draft identity/revision, selected model, send/stop, actual host tools |
| Tool activity | `HanlinToolActivityHeader`, shared hierarchy/disclosure/motion | Real call IDs, accepted arguments, observed result/error/cancellation |
| Approval | `HanlinInlineToolApproval` | The pending original host request and its one-use continuation |
| Sources and auto-follow | Shared sources components and `ChatAutoFollowController` | Observed URLs, viewport geometry and navigation |
| Task dashboard and ChatGPT pairing | Lorvex | Original domain chart and remote bridge; these remain host business capabilities |

`LorvexMobileApp` retains one `LorvexHanlinAssistantState`, which wraps the real
Hanlin session and existing private conversation store. Closing and reopening
the assistant does not create a second conversation owner. Stop revokes the
active run before awaiting session invalidation, so old events/completions cannot
append to or clear a newer turn. Provider identity includes a non-reversible
credential digest, ensuring API-key replacement creates a new session. A failed
Keychain replacement retains the previous credential.

`LorvexHanlinHost` and its 22-tool catalog still route through the actual
`LorvexCoreServicing` implementation. The 12 write tools still require live host
consent. Provider approval never grants host write authority. Activity is keyed
by actual provider call ID; an unfinished activity cannot become a successful
write merely because a text stream ended. The UI never synthesizes task results.

## Focused verification

The existing `Lorvex Hanlin - iPad Agent and IPA` workflow is the native owner.
It installs the exact lock, runs `LorvexHanlinAgentTests` plus the five targeted
presentation/lifecycle regressions, builds the actual arm64 application, then
runs only `HanlinSDKIntegrationTests/testOriginalComposerInsideLorvex` in a fresh
headless iPad Simulator. This real-app route opens the assistant from Lorvex,
types in the original native multiline editor, opens the original Morph panel
and real tool catalog, and reopens the assistant. Screenshots and `.xcresult`
are retained alongside the installation receipt and unsigned IPA provenance.

The UI acceptance test does not make a paid provider request or claim live model
output. Existing tool tests exercise the actual temporary Lorvex Core database,
consent, stale context, read/write results and replay. The focused new tests cover
call correlation, credential rotation, stale cancelled streams, terminal result
truth and source deduplication. Physical-device installation and OAuth pairing
require their separate existing acceptance evidence; an unsigned IPA alone does
not establish those outcomes.

On Oracle, the provisional `a12cf4bac4de9c3d2a60f7620b73306046f40d7a` installation
materialized 285 files / 12,358,971 bytes, with zero binary targets and no native
runtime directories. Installer `--check` and Lorvex's own SwiftPM manifest parse
passed. Native evidence must cite the final lock and consumer commit; this
provisional installation receipt is not a native UI acceptance result.

## Consumer migration receipt, 2026-11-23

The initial migration lock selected SDK `b66aa5e0e979f36d1a34b85e08899449b72d1dc2`,
including canonical localization/assets and the extracted original bubble chrome.
The canonical bootstrap and sparse installer completed successfully against the
actual Lorvex worktree. The installed closure contains 616 files / 27166042 bytes,
with no binary targets or native runtime directories. Selected manifest SHA-256:
`29c126b9305e88bbcaed57512374e986f7225a0c87d332950f6ba3deda9bca26`.

Local review passed Swift syntax for the nine changed/new Swift files, shell and
Python syntax, both workflow/XcodeGen YAML parses, and Git whitespace checks.
Portable source gates passed schema/migration/wire freezes, repository hygiene,
source entitlements/hygiene, design tokens, strategy/build matrix, CloudKit,
MCP typed catalog, plugin vocabulary, localization, acknowledgments/privacy,
core coverage, file sizes, SQLite portability, user docs and watch embedding.

The repository-wide static tier is not reported green: its 873-script-test run
encountered 14 errors and two failures from absent macOS utilities on Linux.
Separate pre-existing failures are the unchanged `bridge/lorvex-mcp-bridge.service`
public machine paths and incomplete owner-branch bundle-ID/build metadata migration
in `script/app_metadata.sh` / `script/build_and_run.sh`. Their bytes equal base
`f7ce8cb7ed4d0d78850d39f64336ecfdb4d6ea7e`; this SDK migration does not change those
operational scripts. `verify_mcp_tool_manifest.py`, despite placement in the
static tier, attempts a Swift build and cannot complete on this Linux host; its
new disposable cache was removed. No native acceptance is inferred from these
checks. The scoped macOS/iPad workflow owns compilation and live UI evidence for
the committed source and exact SDK lock.

## Native acceptance correction (2026-11-23)

Run [45108101654](https://github.com/davidpovarsky/lorvex/actions/runs/45108101654) installed and verified the exact canonical SDK selection on macOS, including its zero-binary receipt. It stopped before source compilation: Lorvex required swift-markdown >=0.8 while the preserved Hanlin streaming renderer requires exactly 0.7.3; an existing Focus Filter XcodeGen runpath setting was incorrectly placed under `configs`. No UI test executed in that run.

The host minimum now admits 0.7.3, and both existing lockfiles select its upstream tag commit `7d9a5ce307528578dfa777d505496bd5f544ad94`. The host's unchanged AST usage (Document, Markup, list checkbox/start index, table head/body/cells, inline nodes and PlainTextConvertibleMarkup) exists in that upstream version. The canonical renderer constraint and implementation are unchanged. The native retry compiles the actual Lorvex markdown module against the shared dependency. The Focus Filter runpaths now belong to `settings.base` for both configurations, preserving their literal values and Release signing configuration.

## Native retry result and targeted corrections

Run [45109608536](https://github.com/davidpovarsky/lorvex/actions/runs/45109608536),
consumer `919a893d8310c7717420c39bcc89c71e95e47925` with SDK `b66aa5e0`,
compiled and ran all 11 selected macOS native tests. All five new
`LorvexHanlinPresentationStateTests` passed. Seven tests passed overall; four
existing agent tests failed with nine issues. The catalog's exact JSON Schema
compiler reported `JSONSchemaCompilationFailure(.metaSchema)`, which also blocked
the dependent read/write/approval/idempotency outcomes. The canonical SDK owner
identified the aggregate package's renamed resource bundle as the cause. Its
checked lookup is corrected in canonical commit `446600ea26dc914a9161885f329893111e746754`,
without changing schema validation semantics.

The independent iPad build failed because the existing EquatableMacros dependency
required Xcode's noninteractive macro enablement. The device and focused Simulator
build invocations now use `-skipMacroValidation`, matching canonical Hanlin native
CI. No successful IPA or XCUI result is claimed for this run. The prior shell
syntax checks are retained; the two changed scripts pass `bash -n` and the Git
diff check. A native retry must use the corrected canonical SDK pin and these
actual host build scripts.

Exact retained artifacts:

| Artifact | GitHub ID | ZIP SHA-256 |
| --- | --- | --- |
| Unit-test evidence | 14790896680 | `82509a8a2210a42143f6332e3fa602b190e514015d3bff947de942af368f2824` |
| Native pipeline diagnostics | 14790693702 | `a89c1e790695a91d4d538d3941070d84e51fb07bcaa0215663af8551b56e9d7b` |

The one watcher encountered an API quota error at 04:39:59 UTC and resumed once
after the 04:43:45 reset. That watcher error was recorded independently of the
actual workflow failure.


## Coherent SDK pin and exact evidence reuse

The host now selects canonical SDK `d49a4fd4115b8335105d2991bf74ab4d7f6aad2d`.
The actual sparse install and read-only `--check` both pass. The seven-product
selection, selected manifest SHA-256 `29c126b9305e88bbcaed57512374e986f7225a0c87d332950f6ba3deda9bca26`,
and zero-binary/zero-managed-native closure remain unchanged. No copied runtime
or second SDK source implementation is introduced.

[HANLIN_SDK_STATE_REUSE_20261123.json](HANLIN_SDK_STATE_REUSE_20261123.json)
records the exact Git objects for the prior passing input trees and every one
of the 15 changed selected SDK source files. The host Agent and Core sources,
pure Swift core, five-test source, host manifest and dependency lock are byte
identical to run `45109608536`. The complete canonical ChatCore,
PlatformContracts and PersistenceAdapters source trees are also byte identical.
The five state tests construct no agent bundle and perform no dispatch/schema
work; they test observed event projection, credential identity and host-owned
cancellation state. Their original five PASS receipts are retained from that
run and artifact, with no new execution claim.

The changed Host1.2 dispatcher, checked JSON Schema bundle loader, and original
UI appearance/motion source are outside that reuse boundary. All six existing
Agent tests must run against this new pin, followed by the actual arm64 iPad
build and `HanlinSDKIntegrationTests/testOriginalComposerInsideLorvex`.
The workflow's default `unit_scope=all` still runs all 11 tests. This corrective
run uses `unit_scope=agent` and an explicit PresentationState suite exclusion;
SwiftPM target names alone would otherwise match that suite too. The native outcome of this corrective run is recorded below; UI acceptance
remains outstanding after the workflow cancellation.

Neither host's current chat composition instantiates Hanlin's extension stores
or CompactAgentClient. Their existing App Groups remain owned by each host; this
pin does not require an invented Hanlin App Group entitlement or Info.plist
dictionary in Lorvex.


## Native result at the coherent pin and UI-only continuation

Run [45119218473](https://github.com/davidpovarsky/lorvex/actions/runs/45119218473)
on consumer `09307ef346eb12be2bcb25141d4b76bc9beb6ed6` and SDK `d49a4fd4`
completed all six `LorvexHanlinAgentTests` successfully: catalog/schema validation,
deny-by-default reads, approved writes/idempotent replay, stale-context refusal,
live remote-bridge approval/idempotency, and malformed/unknown remote-tool refusal.
The six tests ran in 13.081 seconds after actual macOS compilation. The earlier
five state tests were deliberately not rerun.

The actual Debug arm64 iPad application also built and exported an unsigned IPA:
`Lorvex-Hanlin-iPad-1.0.0+171-UNSIGNED.ipa`, 73,455,146 bytes, SHA-256
`50dbf86e408ab0131db85ea8cac0051ed45a80e946fa13dc5d8fbbaf5c2397c7`.
The pipeline log retains the build and export manifest. The IPA was not uploaded:
the upload step followed the UI phase and was skipped when the workflow was
cancelled. This is build/export evidence, not an available binary download,
device installation or signed release acceptance.

The UI step booted its owned iPad Simulator, then received GitHub's
`The operation was canceled.` annotation. The job conclusion is `cancelled`,
not a completed failing assertion. The configured job timeout was 150 minutes;
the annotation does not identify the origin of cancellation. Its UI log is empty,
and no `xcresult` or screenshot was retained. No native UI execution or visual
acceptance is inferred from this run.

[HANLIN_NATIVE_ACCEPTANCE_20261123.json](HANLIN_NATIVE_ACCEPTANCE_20261123.json)
records the source objects, exact native outcomes and artifact SHA-256 values.
The bounded `validation_scope=ui` continuation first verifies those original
source objects and the immutable SDK lock, then invokes the unchanged
`verify_hanlin_host_ui.sh` and original test selector. It does not repeat the
six Agent tests or the successful device build, and changes no UI assertion or
test timeout. Default `validation_scope=full` retains normal validation; successful
full-run device artifacts are now preserved before beginning the separate UI gate.

| Retained artifact | GitHub ID | ZIP SHA-256 |
| --- | --- | --- |
| Six native Agent tests | 14794586293 | `a71498ac5400f691532a88363941218cf8bbd451c90965a6550dc556ac081af9` |
| Device build and cancelled-UI diagnostics | 14794868870 | `261bbc54ac385219b3bbb104cc0161f66c61c9c134f156e38b6e297a7c15a3ab` |
