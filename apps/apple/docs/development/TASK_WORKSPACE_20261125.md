# Live task workspace — Lorvex

## Source and ownership

This lane starts from the user's integration branch
`codex/lorvex-final-20261124` at
`b0db80213e78e378e9ac9bb367fa7516746cd846`, which includes the signed
Lorvex 172 source and subsequent cloud throttle fixes. It is implemented in
`codex/lorvex-visual-tasks-20261125` in an isolated Oracle worktree.
The independent canonical clone is
`/mnt/development/projects/worktrees/lorvex-visual-tasks-owned-20261125`;
its `origin` is the user's `davidpovarsky/lorvex` fork. The earlier shared-mirror
worktree is preserved and is not the writer for this lane.

## Product behavior

- **Tasks → Task workspace** opens a native graph, board, timeline, network and table.
- A task list's toolbar opens the same workspace scoped to that list.
- Every node/card uses the canonical task ID. Open shows the existing task detail,
  including its editor, checklist, reminders and lifecycle actions.
- Add creates a real task through the existing MobileStore pipeline.
- Completion, reopening, status moves, date changes and dependency edits use
  the existing service, mutation guards, outbox and surface refresh.
- The board respects Lorvex's existing state transitions. Starting requires an
  open task and satisfied prerequisites. An invalid drop is rejected and the
  view reloads the original stored state; it does not partially reopen a task.
- Reopening a prerequisite never automatically clears completed downstream work.
- Planned dates and due dates stay independent and use PlannedDayBridge between
  UTC storage dates and local date pickers.
- Full/peer/MCP reloads advance taskWorkspaceRevision, which invalidates the
  visible workspace. Rejected writes reload, while a post-commit read failure
  is displayed as a separate read warning rather than a retryable write error.
- The bounded canonical graph retains its truncation warning; dependencies
  outside the visible scope continue to influence real blockers.

## Hanlin integration

Hanlin's original chat shell, composer and runtime remain unchanged.
The host exposes 26 scoped tools, including:

| Tool | Behavior |
| --- | --- |
| show_task_workspace | Read and validate scope, then attach a view descriptor to the current assistant message. |
| get_dependency_graph | Return real task nodes and explicit prerequisiteID/dependentID edges. |
| add_task_dependency | Add one prerequisite through the canonical task patch/cycle validation. |
| remove_task_dependency | Remove only that prerequisite relation. |

The existing create_task/update_task tools additionally accept depends_on.
A successful show tool result creates a native interactive workspace inside the
message, with an expansion button. The descriptor contains IDs and presentation
only; its tasks are read live from MobileStore. A failed, malformed or unobserved
tool result never creates a successful view. The assistant also has a manual
workspace entry that requires no model inference.

## Original dependency boundaries

TaskVisualizationKit is consumed from
https://github.com/davidpovarsky/task-visualization-kit.git at an immutable revision.
The release coordinator updates that pin to the compiled and tested revision before
archive. Its SwiftFlow, AdvancedKanban and ForceGraph sources are original,
revision-pinned SwiftPM dependencies. No upstream implementation is copied or modified
in Lorvex. Only LorvexMobile links the shared kit; the executable passes a String
presentation name through the mobile adapter to avoid duplicate static linkage.

The package's bundled notices are also represented in Lorvex's acknowledgment
metadata. After final native resolution, run
`python3 apps/apple/script/generate_acknowledgments.py` and the existing verifier
against the final Package.resolved before release.

## Checks owned by the release coordinator

No native build, test or TestFlight outcome is claimed by this implementation note.
The following new checks are ready for the existing Scaleway Mac lane:

- `MobileTaskWorkspaceTests`: canonical ID/dependency mapping, cycle rejection,
  blocked and invalid status moves without partial writes, independent dates,
  persistence after opening a second real SQLite service, and downstream completion
  surviving a reopened prerequisite.
- `LorvexHanlinTaskWorkspaceTests`: real dependency tools, graph edge direction,
  view descriptor identity, failed/malformed tool rejection and idempotent rendering.
- Updated `LorvexHanlinAgentTests` catalog and original write-authorization checks.
- `LorvexMobileUITests/TaskWorkspaceIntegrationTests/testVisualTaskCompletionSurvivesRelaunch`:
  UI creation of two real test tasks, connecting them, setting a real due date,
  all five presentations with screenshots (including a populated timeline),
  prerequisite completion, live table completion, verification in the original
  task detail, and relaunch/persisted completion and date followed by reopening.
  The test runner reads `LORVEX_TEST_LANGUAGE=en|he` (default `en`) and sets the
  application language/locale explicitly. It verifies translated mode labels
  and completion controls and scrolls the mode picker according to direction.
  Inject the variable into the UI test target's `EnvironmentVariables` in a
  copied `.xctestrun` file, then use `test-without-building` on the isolated
  iPad and iPhone destinations. A test runner `-testLanguage` alone does not
  override an application's explicit launch arguments. The test explicitly sets
  `LORVEX_CLOUD_SYNC=off` for the application. Use fresh owned simulators with
  no saved account; keep the per-language `.xctestrun` files beside the original
  in `Build/Products` so `__TESTROOT__` continues to resolve the exact products.

Native compiler/test evidence, final kit/source pins and the new TestFlight build
belong in the release receipt after those stages actually run.


## Isolated release runner configuration

The release owner can keep the existing archive/export gates while selecting
per-task caches through optional `archive_ios.sh` environment variables:

- `LORVEX_DERIVED_DATA_PATH` supplies `-derivedDataPath`.
- `LORVEX_CLONED_SOURCE_PACKAGES_DIR` supplies
  `-clonedSourcePackagesDirPath` and `-scmProvider system`, allowing the existing
  process-scoped Git URL mirror to resolve the private shared kit.

Unset variables preserve the existing Xcode defaults. This configuration change
does not run an archive or weaken signing, schema-freeze, export, or IPA gates.


## Focused native acceptance controller

`script/verify_task_workspace_native.py` prints a plan by default. Its
`--execute` mode is reserved for the explicitly granted, single-owner Mac
validation slot. It has no archive, upload, push, or release-control operation.

The controller runs the four focused Swift Testing suites
`MobileTaskWorkspaceTests`, `LorvexHanlinTaskWorkspaceTests`,
`LorvexHanlinAgentTests`, and `SwiftLorvexCoreServiceInProgressTests`.
The first three cover the new projection/mutations, descriptor rendering,
and the existing tool catalog/authorization. The core suite verifies the
underlying status and prerequisite transitions. Actual case names, results,
counts, raw logs, and xUnit output are retained.

It then performs one ad-hoc signed arm64 `build-for-testing` with two jobs
and executes the exact resulting products on four newly created simulators:
iPhone/en, iPhone/he, iPad/en, and iPad/he. Runtime and device compatibility are
checked against the installed metadata. Each configuration keeps its complete
xcresult, structured result summary, attachments and log hashes. The UI test
attaches the actual task/prerequisite IDs and completed/date persistence after
relaunch only after all assertions and canonical reopening succeed.

Example plan (supply the final source SHA after integration and dependency pinning):

```sh
/opt/homebrew/bin/python3.12 apps/apple/script/verify_task_workspace_native.py \
  --expected-sha FINAL_40_CHARACTER_SHA \
  --output /Users/m1/builds/lorvex-visual-173-20261125/evidence/acceptance-RUN_ID \
  --derived-data /Users/m1/caches/DerivedData/lorvex-visual-173-20261125 \
  --source-packages /Users/m1/caches/DerivedData/lorvex-visual-173-20261125/SourcePackages \
  --kit-mirror /Users/m1/builds/task-visualization-kit-20261125/kit.git
```

Add `--execute` only for the assigned Mac slot. The optional `--phase`
selects `unit`, `build`, `ui`, or `all`; `--cases` permits a focused
diagnostic configuration. A UI-only run requires `--build-receipt` pointing
to a passing build receipt for the exact same SHA and unchanged products.
Partial runs explicitly report `matrixComplete: false`.

All evidence must live outside the source checkout. The controller refuses
an existing output directory, preserves failed simulators for diagnosis after
shutting them down, and deletes only its own successful simulators after
exporting evidence. Representative original screenshots are copied to
`screenshots/<device>-<language>-<mode>.png` with their hashes and original
attachment metadata; no screenshot pixels are modified. A failing case stops
the remaining matrix until the specific problem is resolved.
