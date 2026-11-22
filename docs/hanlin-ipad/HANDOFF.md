# Lorvex × HanlinAgentSDK / iPad IPA
Date: 2026-11-22

## Sources
- Lorvex upstream: https://github.com/boyugou/lorvex at dc7988b9dd67
- Working fork: https://github.com/davidpovarsky/lorvex
- Branch: feat/hanlin-ipad-ipa-20261122
- Hanlin source: davidpovarsky/hanlin-ai codex/hanlin-agy-integration-20261122 at a8edb565
- SDK: apps/apple/Vendor/HanlinAgentSDK and Vendor/HanlinPlatform from original, licenses retained. The SDK uses the pinned swift-ai-sdk revision e7bf34111e603ca977becd007dd4e5bb109af857.

## iPad assistant architecture
- Original Lorvex SwiftLorvexCoreService remains the sole owner of task/list/event/habit data.
- The mobile MobileStore provides the same existing core to the LorvexHanlinHost adapter; no parallel DB, no duplicate MCP engine.
- LorvexHanlinAgent is a SwiftPM/XcodeGen framework target, with the real HanlinAgentSession streaming, HanlinHostIntegration/Dispatcher, JSON Schema validation and private conversation store.
- UI is a native SwiftUI assistant sheet in LorvexMobileApp. It has model settings, stream text, action receipts and interactive approval prompts.
- The model provider token is read from/written to Keychain, not stored in repo or user defaults.
- This integration uses provider API credentials; it does NOT authorize ChatGPT account sign-in.
- Minimum iPadOS deployment target raised to 27.0 because current HanlinAgentSDK requires it.

## Tool surface
22 declared and validated tools, 10 reads (tasks, task search, summary, today, lists, calendar, habits) and 12 writes (task CRUD lifecycle, plan, calendar create, list create and habit completion).
All writes are denied by default until the live UI explicitly approves. The adapter rechecks context before writes and handles ambiguous post-dispatch results as uncertain.

## IPA
- Script: apps/apple/script/build_hanlin_ipad_ipa.sh
- CI: .github/workflows/lorvex-hanlin-ipad-ipa.yml on Xcode 27 runner
- CI checks: package tests and app Release iOS arm64 compilation independently, schema-freeze verification, bundle Info.plist, arm64, valid Payload/*.app zip archive and sha256 manifest.
- Without distribution credentials, the script produces UNSIGNED IPA only. This is a real IPA archive but cannot be installed directly or uploaded to TestFlight without signing/provisioning.
- For installable output, configure authorized Apple Team ID, signing assets and run upstream apps/apple/script/archive_ios.sh --export.
- Do not claim that the IPA exists or works until the workflow creates and validates its artifact; do not mark signed IPA complete without its signature validation.

## Status
Initial Apple CI: https://github.com/davidpovarsky/lorvex/actions/runs/45071179322
- Setup/XcodeGen/schema-freeze and source checkout passed.
- SwiftPM and iOS build both stopped at the same resource copy error:
  Vendor/HanlinAgentSDK/Vendor/Swift-JSON/Sources/JSONSchema/Resources/Draft2020-12 missing.
- Cause: first Windows SDK vendor copy was interrupted and left 46 SDK files absent.
- Reconciled all SDK files against the passing GSD vendor checkout, then verified
  SHA256 identity of EVERY SDK file (159 HanlinAgentSDK, 231 HanlinPlatform).
- Added native Swift Charts summary card, with Status/Priority segmented
  controls using the actual get_summary tool JSON, not fabricated metrics.
- Added an end-to-end summary JSON-to-chart-data assertion in Hanlin unit tests.
- Re-validation after repair: Swift parse passed; Native Apple tests and IPA
  build must be rerun on this corrected branch. Never count failed CI as success.


## Apple CI 45071802426 diagnostic and correction
- Original SDK schema resource issue eliminated. Both Swift tests and Xcode
  Release build reached LorvexHanlinAgent.
- Both failed at one compile error in LorvexHanlinHost: LorvexTask has no
  isActionable member, but LorvexTask.Status does.
- Fixed to task.status.isActionable in the task-summary aggregation.
- Test fixture now models an attributed explicit user write
  (writeInitiatorDefault=user), not an implicit unauthenticated write.
- To avoid unnecessary SwiftAISDK whole-module Release optimization for an
  unsigned trial, IPA script defaults to Debug ARM64. Use environment variable
  LORVEX_IPA_CONFIGURATION=Release to produce a Release build. Signed
  archive_ios.sh is unchanged.
- Next Apple CI must pass both tests and build and upload IPA before a completion claim.
