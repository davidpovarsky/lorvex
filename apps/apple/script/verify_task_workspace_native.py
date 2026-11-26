#!/usr/bin/env python3
"""Prepare or execute focused Lorvex native acceptance on the coordinated Mac.

Default behavior prints a plan only. --execute is for the explicitly granted
Mac validation slot. This controller never archives, uploads, pushes, changes
global Git settings, or reuses a simulator containing an account.
"""
from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import time
import uuid
import xml.etree.ElementTree as ET

def sibling_module(name: str):
    path = Path(__file__).with_name(name + ".py")
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


runtime_closure = sibling_module("task_workspace_runtime_closure")


UI_TARGET = "LorvexMobileUITests"
UI_CASE = "TaskWorkspaceIntegrationTests/testVisualTaskCompletionSurvivesRelaunch"
UI_SELECTOR = f"{UI_TARGET}/{UI_CASE}"
HOST_UI_CASES = (
    "HanlinSDKIntegrationTests/testOriginalComposerInsideLorvex",
    "HanlinSDKIntegrationTests/testHebrewCloudAndChatGPTSettings",
    "HanlinSDKIntegrationTests/testMCPConnectionUsesCloudAccount",
    "HanlinSDKIntegrationTests/testChatGPTSignInCanBeCancelledAndRestarted",
)
HOST_UI_SELECTORS = tuple(f"{UI_TARGET}/{case}" for case in HOST_UI_CASES)
UNIT_SUITES = (
    "MobileTaskWorkspaceTests",
    "LorvexHanlinTaskWorkspaceTests",
    "LorvexHanlinAgentTests",
    "SwiftLorvexCoreServiceInProgressTests",
    "LorvexHanlinPresentationStateTests",
    "LorvexCloudAccountSyncTests",
)
UNIT_SUITE_NAMES = {
    "MobileTaskWorkspaceTests", "LorvexHanlinTaskWorkspaceTests",
    "LorvexHanlinAgentTests", "Core service in_progress",
    "LorvexHanlinPresentationStateTests", "Lorvex Cloud account sync",
}
UNIT_FUNCTIONS = (
    "appMetadataMatchesAppleDistributionIdentity",
    "appMetadataUsesSharedProductMetadata",
    "publicContactURLsPointAtLorvexAppNotGitHub",
    "backgroundDatabaseWorkHoldsABackgroundTaskThatSuspendsOnExpiry",
    "backgroundFlushWritesAutosaveDraftsBeforeItsSyncPass",
    "backgroundWakesReachTheStoreAndSyncBeforeReminders",
    "backgroundWakesAdoptWhatTheyApplied",
)
REQUIRED_UNIT_TESTS = (
    "dependenciesUseOriginalIDsAndRejectCyclesWithoutLosingOtherFields",
    "boardUsesCanonicalBlockedStartAndDoesNotPartiallyReopen",
    "cancelledAndSomedayRemainEditableButAreNotReady",
    "workspaceEditsSurviveStoreReopenAndPreserveIndependentDates",
    "workspaceIncludesIndependentTasksAndKeepsListAndRootScopes",
    "workspaceInventoryIsBoundedAndReportsMoreIndependentTasks",
    "workspaceCommitsBeforeSlowPublicationsAndCoalescesLatestState",
    "toolsWriteRealDependenciesAndReturnLiveViewDescriptors",
    "failedOrMalformedToolNeverCreatesAWorkspaceAndReplayIsStable",
    "workspaceDescriptorCountsIndependentTasksAcrossStatuses",
    "visualWorkspaceMutationsConvergeThroughCanonicalCloudSync",
    "catalogValidatesAndIncludes26ScopedTools",
    "readsAndDenyByDefaultCannotModifyTasks",
    "approvedCreateAndIdempotentReplay",
    "staleContextDoesNotWrite",
    "remoteBridgeRequiresLiveApprovalAndIsIdempotent",
    "remoteBridgeRejectsUnknownToolAndMalformedArguments",
    "activityKeepsDistinctCallsAndObservedResultState",
    "cancellationCannotPublishIntoTheNextRequest",
    "changedCredentialCreatesADifferentProviderIdentity",
    "sourcesAreObservedDeduplicatedAndSafeForNavigation",
    "failedOrCancelledToolCannotBecomeACompletedReceipt",
    "interruptedFirstSyncBindsBeforeNetworkAndRejectsAnotherAccount",
    "lostPushReceiptAndRestartPreserveDataWithoutDuplicates",
    "concurrentServerLifecycleAndLocalTitleUseCanonicalJoin",
    "logoutInvalidatesAnInflightPullBeforeItCanApplyOrCheckpoint",
    "regressingCursorIsRejectedWithoutChangingCheckpoint",
    "failedBackfillIsNotMarkedInitializedAndReseedIsRetried",
    "malformedPayloadDoesNotAdvanceTheCursor",
    "foregroundBeforeSavedAccountRestorationStillStartsSync",
    "oracleBindingKeepsCloudKitOffThroughLogoutAndFactoryRecreation",
    "unauthorizedAccessRefreshesExactlyOnceAndKeepsAccountIdentity",
) + UNIT_FUNCTIONS
MINIMUM_UNIT_TESTS = 49  # 7 workspace + 3 workspace agent + 6 agent + 10 core + 5 state + 11 cloud + 7 functions.
DEVICE_TYPES = {
    "iphone": "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
    "ipad": "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB",
}
MATRIX = ("iphone-en", "iphone-he", "ipad-en", "ipad-he")
KIT_URL = "https://github.com/davidpovarsky/task-visualization-kit.git"
MODES = ("graph", "board", "timeline", "network", "table")
PLAN_METHOD = "canonicalAgentExecutesNamespacedToolAndContinuesExactlyOnce"
PLAN_SELECTOR = "HanlinChatGPTPlanTests/" + PLAN_METHOD
PLAN_INPUTS = {
    "HanlinChatGPTPlanClient.swift": (
        "Packages/HanlinPlatform/Sources/HanlinChatCore/HanlinChatGPTPlanClient.swift",
        "14f8bc46a2590eb483b94d292e05a37d732cb34af207872faf897abe50bc3aab",
    ),
    "HanlinChatGPTPlanWire.swift": (
        "Packages/HanlinPlatform/Sources/HanlinChatCore/HanlinChatGPTPlanWire.swift",
        "18fed34ca6de1742f18b5b59bd3b4774103acfce57e44803ff537818e8327900",
    ),
    "verify_chatgpt_plan_contract.swift": (
        "Scripts/Tests/verify_chatgpt_plan_contract.swift",
        "e9726a19dcd4f3ef1487dc5ad548d44825991011dccc1663e8c92e88076057f7",
    ),
    "HanlinChatGPTPlanTests.swift": (
        "Packages/HanlinPlatform/Tests/HanlinChatCoreTests/HanlinChatGPTPlanTests.swift",
        "d2f061d50a2deabf73847afecd1c78d1577ce6bca1ce4390e5a4161d140bde55",
    ),
}


def utc() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix(path.suffix + ".tmp")
    temp.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")
    temp.replace(path)


def targets(manifest: dict):
    if "TestConfigurations" in manifest:
        for configuration in manifest["TestConfigurations"]:
            for target in configuration.get("TestTargets", []):
                if target.get("BlueprintName") == UI_TARGET:
                    yield target
    elif isinstance(manifest.get(UI_TARGET), dict):
        yield manifest[UI_TARGET]


def test_cases(nodes: list[dict]):
    for node in nodes:
        if node.get("nodeType") == "Test Case":
            yield node
        yield from test_cases(node.get("children", []))


def unit_xml_evidence(output: Path) -> tuple[Path | None, list[dict], list[dict]]:
    combined = ET.Element("testsuites")
    sources = []
    for path in (output / "unit-results.xml", output / "unit-results-swift-testing.xml"):
        if not path.exists():
            continue
        root = ET.parse(path).getroot()
        suites = [root] if root.tag == "testsuite" else root.findall("testsuite")
        for suite in suites:
            combined.append(suite)
        sources.append({"path": str(path), "sha256": digest(path)})
    if not sources:
        return None, [], []
    destination = output / "unit-results-combined.xml"
    ET.ElementTree(combined).write(destination, encoding="utf-8", xml_declaration=True)
    cases = []
    for case in combined.iter("testcase"):
        status = "Failed" if case.find("failure") is not None or case.find("error") is not None else (
            "Skipped" if case.find("skipped") is not None else "Passed")
        identifier = "/".join((
            case.get("classname", "").replace(".", "/"),
            case.get("name", "").split("(", 1)[0],
        ))
        cases.append({**case.attrib, "identifier": identifier, "result": status})
    return destination, cases, sources


def stop_process(process: subprocess.Popen) -> None:
    if process.poll() is not None:
        return
    os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=10)


class Controller:
    def __init__(self, args: argparse.Namespace):
        self.args = args
        self.source = args.source.resolve()
        self.apple = self.source / "apps/apple"
        self.out = args.output.resolve()
        self.dd = args.derived_data.resolve()
        self.packages = (args.source_packages or self.dd / "SourcePackages").resolve()
        self.project_dir = self.apple / "dist/xcode-task-workspace"
        self.project = self.project_dir / "LorvexAppleNative.xcodeproj"
        self.env = os.environ.copy()
        self.env["NO_COLOR"] = "1"
        if args.developer_dir:
            self.env["DEVELOPER_DIR"] = str(args.developer_dir.resolve())
        if args.kit_mirror:
            count = int(self.env.get("GIT_CONFIG_COUNT", "0"))
            self.env[f"GIT_CONFIG_KEY_{count}"] = "url." + args.kit_mirror.resolve().as_uri() + ".insteadOf"
            self.env[f"GIT_CONFIG_VALUE_{count}"] = KIT_URL
            self.env["GIT_CONFIG_COUNT"] = str(count + 1)
        self.ui_env = self.env.copy()
        if args.ui_developer_dir:
            self.ui_env["DEVELOPER_DIR"] = str(args.ui_developer_dir.resolve())
        self.receipt = {
            "schemaVersion": 1,
            "sourceSHA": args.expected_sha,
            "startedUTC": utc(),
            "source": str(self.source),
            "output": str(self.out),
            "derivedData": str(self.dd),
            "sourcePackages": str(self.packages),
            "controllerSHA256": digest(Path(__file__).resolve()),
            "phase": args.phase,
            "requestedCases": args.cases,
            "requiredMatrix": list(MATRIX),
            "requiredHostUICases": list(HOST_UI_CASES),
            "buildJobs": 2,
            "compilerDeveloperDir": self.env.get("DEVELOPER_DIR"),
            "uiDriverDeveloperDir": self.ui_env.get("DEVELOPER_DIR"),
            "result": "running",
            "steps": [],
            "cases": [],
        }

    def save(self):
        write_json(self.out / "receipt.json", self.receipt)

    def raw_git(self, *args: str) -> str:
        return subprocess.check_output(
            ["git", "-C", str(self.source), *args], text=True, env=self.env
        ).strip()

    def assert_source(self):
        actual = self.raw_git("rev-parse", "HEAD")
        if actual != self.args.expected_sha:
            raise RuntimeError(f"Expected source {self.args.expected_sha}, found {actual}")
        dirty = self.raw_git("status", "--porcelain")
        if dirty:
            raise RuntimeError("Source is not clean; preserve and review the changes before native acceptance.")
        self.receipt["sourceTree"] = self.raw_git("rev-parse", "HEAD^{tree}")

    def run(self, name: str, command: list[str], *, timeout: int = 120,
            check: bool = True, ui_driver: bool | None = None) -> tuple[int, Path]:
        command = [str(x) for x in command]
        if ui_driver is None:
            ui_driver = (
                command[:2] in (["xcrun", "simctl"], ["xcrun", "xcresulttool"])
                or (command[0] == "xcodebuild" and "test-without-building" in command)
            )
        command_env = self.ui_env if ui_driver else self.env
        log = self.out / "logs" / f"{len(self.receipt['steps']):03d}-{name}.log"
        log.parent.mkdir(parents=True, exist_ok=True)
        step = {
            "name": name, "command": command, "startedUTC": utc(), "log": str(log),
            "toolchainRole": "ui-driver" if ui_driver else "compiler",
            "developerDir": command_env.get("DEVELOPER_DIR"),
        }
        self.receipt["steps"].append(step)
        self.save()
        started = time.monotonic()
        code = 130
        try:
            with log.open("w") as stream:
                process = subprocess.Popen(
                    command, cwd=self.source, env=command_env, stdout=stream,
                    stderr=subprocess.STDOUT, start_new_session=True
                )
                try:
                    code = process.wait(timeout=timeout)
                except subprocess.TimeoutExpired:
                    step["timedOut"] = True
                    stop_process(process)
                    code = 124
                except BaseException:
                    stop_process(process)
                    raise
        finally:
            step.update({
                "exitCode": code, "finishedUTC": utc(),
                "durationSeconds": round(time.monotonic() - started, 3),
                "logSHA256": digest(log),
            })
            self.save()
            print(json.dumps({"stage": name, "exitCode": code, "log": str(log)}), flush=True)
        if check and code:
            raise RuntimeError(f"{name} failed with exit {code}; see {log}")
        return code, log

    def json_command(self, name: str, command: list[str]) -> dict | list:
        _, log = self.run(name, command)
        return json.loads(log.read_text())

    def unit_command(self):
        return [
            "xcrun", "swift", "test", "--package-path", str(self.apple),
            "--scratch-path", str(self.dd / "SwiftPM"),
            "--disable-automatic-resolution", "--skip-update", "--jobs", "2",
            "--no-parallel", "--filter", "|".join(UNIT_SUITES + UNIT_FUNCTIONS),
            "--xunit-output", str(self.out / "unit-results.xml"),
        ]

    def plan_engine_command(self):
        harness = (self.args.plan_harness or Path("<configured-plan-harness>")).resolve()
        return [
            "xcrun", "swift", "test", "--package-path", str(harness),
            "--scratch-path", str(harness.parent / "build"),
            "--cache-path", str(harness.parent / "cache"),
            "--force-resolved-versions", "--skip-update", "-j", "2",
            "--disable-xctest", "--enable-swift-testing", "--no-parallel",
            "--filter", PLAN_SELECTOR, "--xunit-output", str(self.out / "plan-engine-results.xml"),
        ]

    def build_command(self):
        return [
            "xcodebuild", "-project", str(self.project), "-scheme", UI_TARGET,
            "-configuration", "Debug", "-destination", "generic/platform=iOS Simulator",
            "-derivedDataPath", str(self.dd), "-clonedSourcePackagesDirPath", str(self.packages),
            "-scmProvider", "system", "-jobs", "2",
            "-onlyUsePackageVersionsFromResolvedFile", "-disableAutomaticPackageResolution",
            "-parallel-testing-enabled", "NO", "-skipMacroValidation",
            "-resultBundlePath", str(self.out / "native-build.xcresult"),
            "ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES",
            "CODE_SIGNING_ALLOWED=YES", "CODE_SIGN_IDENTITY=-", "build-for-testing",
        ]

    def ui_command(self, manifest: Path, simulator: str, language: str, result: Path,
                   selectors: tuple[str, ...] = (UI_SELECTOR,)):
        return [
            "xcodebuild", "-xctestrun", str(manifest),
            "-destination", f"platform=iOS Simulator,id={simulator}",
            "-destination-timeout", "90", "-jobs", "2",
            "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never",
            "-testLanguage", language, "-testRegion", "IL" if language == "he" else "US",
            "-resultBundlePath", str(result),
            *("-only-testing:" + selector for selector in selectors),
            "test-without-building",
        ]

    def plan(self) -> dict:
        return {
            "mode": "plan-only; no build, test, or simulator action",
            "sourceSHA": self.args.expected_sha,
            "source": str(self.source),
            "output": str(self.out),
            "unitSuites": list(UNIT_SUITES),
            "unitFunctions": list(UNIT_FUNCTIONS),
            "minimumUnitCases": MINIMUM_UNIT_TESTS,
            "unitCommand": self.unit_command(),
            "nativeBuildCommand": self.build_command(),
            "freshPlanEngineCommand": self.plan_engine_command(),
            "freshStandalonePlanContract": "VerifyChatGPTPlanContract.main (all macOS OAuth/wire checks)",
            "compilerDeveloperDir": self.env.get("DEVELOPER_DIR"),
            "uiDriverDeveloperDir": self.ui_env.get("DEVELOPER_DIR"),
            "caseCommands": {
                key: self.ui_command(
                    self.dd / "Build/Products" / f"LorvexMobileUITests.workspace-{key[-2:]}.xctestrun",
                    "<fresh-owned-" + key + "-simulator>", key[-2:],
                    self.out / key / "result.xcresult",
                ) for key in self.args.cases
            },
            "hostUICommand": self.ui_command(
                self.dd / "Build/Products/LorvexMobileUITests.workspace-en.xctestrun",
                "<fresh-owned-host-ipad-simulator>", "en",
                self.out / "hanlin-host-ipad/result.xcresult", HOST_UI_SELECTORS,
            ),
            "runtime": self.args.runtime,
            "deviceTypes": DEVICE_TYPES,
            "archiveOrUpload": False,
        }

    def preflight(self):
        self.assert_source()
        self.receipt["controllerProcess"] = {
            "pid": os.getpid(), "parentPID": os.getppid(),
            "executable": str(Path(sys.executable).resolve()),
        }
        self.receipt["inputSHA256"] = {
            name: digest(self.source / name) for name in (
                "HanlinSDK.lock.json", "apps/apple/Package.swift",
                "apps/apple/Package.resolved", "apps/apple/Config/XcodeGen/project.yml",
                "apps/apple/Config/XcodeGen/Package.resolved",
                "apps/apple/Tests/LorvexMobileUITests/TaskWorkspaceIntegrationTests.swift",
                "apps/apple/Tests/LorvexMobileUITests/HanlinSDKIntegrationTests.swift",
                "apps/apple/script/task_workspace_runtime_closure.py",
                "apps/apple/script/task_workspace_notification_readiness.py",
            )
        }
        self.receipt["gitObjects"] = {
            name: self.raw_git("rev-parse", "HEAD:" + name)
            for name in (
                "apps/apple/Sources/LorvexMobile", "apps/apple/Sources/LorvexHanlinAgent",
                "apps/apple/Sources/LorvexCore", "apps/apple/core",
                "apps/apple/Tests/LorvexAppleTests/MobileTaskWorkspaceTests.swift",
                "apps/apple/Tests/LorvexAppleTests/LorvexCloudAccountSyncTests.swift",
                "apps/apple/Tests/LorvexAppleTests/AppMetadataTests.swift",
                "apps/apple/Tests/LorvexAppleTests/NotificationActionsTests.swift",
                "apps/apple/Tests/LorvexAppleTests/MobileReviewTests.swift",
                "apps/apple/Tests/LorvexAppleTests/MobileStoreBackgroundAdoptionTests.swift",
                "apps/apple/Sources/LorvexMobileApp",
                "apps/apple/Tests/LorvexHanlinAgentTests",
                "apps/apple/Tests/LorvexCoreServiceTests/SwiftLorvexCoreServiceInProgressTests.swift",
            )
        }
        for name, command in (
            ("xcode-version", ["xcodebuild", "-version"]),
            ("swift-version", ["xcrun", "swift", "--version"]),
            ("selected-developer", ["xcode-select", "-p"]),
            ("disk", ["df", "-h", str(self.dd)]),
            ("memory", ["memory_pressure"]),
            ("load", ["sysctl", "vm.loadavg"]),
            ("sdk-check", [sys.executable, str(self.apple / "script/install_hanlin_sdk.py"), "--check"]),
            ("acknowledgments", [sys.executable, str(self.apple / "script/verify_acknowledgments.py")]),
        ):
            self.run(name, command)
        self.run("ui-driver-version", ["xcodebuild", "-version"], ui_driver=True)
        _, sdk_log = self.run("simulator-sdk", ["xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"])
        self.receipt["simulatorSDK"] = sdk_log.read_text().strip()
        self.save()

    def sdk_plan_acceptance(self):
        if not self.args.plan_harness:
            raise RuntimeError("--plan-harness must name the coordinator-owned original SDK regression harness.")
        harness = self.args.plan_harness.resolve()
        sdk = harness.parent / "source"
        fixture = harness.parent / "plan-contract-source"
        revision = json.loads((self.source / "HanlinSDK.lock.json").read_text())["revision"]
        sdk_head = subprocess.check_output(["git", "-C", str(sdk), "rev-parse", "HEAD"], text=True).strip()
        if sdk_head != revision or subprocess.check_output(
            ["git", "-C", str(sdk), "status", "--porcelain"], text=True
        ).strip():
            raise RuntimeError("Plan harness SDK must be clean at the host's exact SDK revision.")
        inputs = {}
        for filename, (relative, expected) in PLAN_INPUTS.items():
            source = harness / "Tests/HanlinChatCoreTests" / filename if filename.endswith("Tests.swift") else fixture / filename
            if digest(source) != expected:
                raise RuntimeError("Original pinned Plan fixture changed: " + str(source))
            if filename in ("HanlinChatGPTPlanClient.swift", "HanlinChatGPTPlanWire.swift"):
                if digest(self.source / "Vendor/HanlinSDK" / relative) != expected or digest(sdk / relative) != expected:
                    raise RuntimeError("Installed and harness SDK Plan source disagree.")
            inputs[relative] = {"path": str(source), "sha256": expected}
        engine_relative = "Packages/HanlinPlatform/Sources/HanlinChatCore/HanlinAISDKAgentEngine.swift"
        engine_sha = digest(sdk / engine_relative)
        if digest(self.source / "Vendor/HanlinSDK" / engine_relative) != engine_sha:
            raise RuntimeError("The original harness engine differs from the installed app SDK engine.")
        inputs[engine_relative] = {"path": str(sdk / engine_relative), "sha256": engine_sha}
        inputs["harness/Package.swift"] = {"path": str(harness / "Package.swift"), "sha256": digest(harness / "Package.swift")}
        inputs["harness/Package.resolved"] = {"path": str(harness / "Package.resolved"), "sha256": digest(harness / "Package.resolved")}
        self.receipt["sdkPlanInputs"] = {"sdkRevision": revision, "inputs": inputs}
        self.save()

        code, log = self.run("fresh-plan-engine", self.plan_engine_command(), timeout=1800, check=False)
        xml = self.out / "plan-engine-results.xml"
        cases = []
        if xml.exists():
            for case in ET.parse(xml).iter("testcase"):
                result = "Passed" if all(case.find(key) is None for key in ("failure", "error", "skipped")) else "FailedOrSkipped"
                cases.append({**case.attrib, "result": result})
        passed_lines = [
            line.strip() for line in log.read_text().splitlines()
            if re.search(r"[✔✓] Test " + PLAN_METHOD + r"\(\) passed after ", line)
        ]
        accepted = (
            code == 0 and len(cases) == 1 and cases[0]["result"] == "Passed"
            and PLAN_METHOD in cases[0].get("name", "") and len(passed_lines) == 1
            and re.search(r"Test run with 1 test.*passed", log.read_text()) is not None
        )
        engine_record = {
            "sourceSHA": self.args.expected_sha, "sdkRevision": revision,
            "testIdentifier": "HanlinChatCoreTests/" + PLAN_SELECTOR,
            "result": "passed" if accepted else "failed", "exitCode": code,
            "cases": cases, "passedLines": passed_lines, "inputs": inputs,
            "log": str(log), "logSHA256": digest(log),
            "xunitPath": str(xml) if xml.exists() else None,
            "xunitSHA256": digest(xml) if xml.exists() else None,
        }
        self.receipt["sdkPlanEngine"] = engine_record
        write_json(self.out / "sdk-plan-engine-receipt.json", engine_record)
        self.save()
        if not accepted:
            raise RuntimeError("The exact original ChatGPT Plan engine case did not pass.")

        contract_dir = self.out / "sdk-plan-contract-source"
        contract_dir.mkdir()
        contract_files = [
            "HanlinChatGPTPlanClient.swift", "HanlinChatGPTPlanWire.swift", "verify_chatgpt_plan_contract.swift",
        ]
        for filename in contract_files:
            shutil.copyfile(fixture / filename, contract_dir / filename)
        binary = self.out / "verify-chatgpt-plan-contract"
        compile_code, compile_log = self.run("plan-contract-compile", [
            "xcrun", "swiftc", "-swift-version", "6", "-parse-as-library",
            *(str(contract_dir / filename) for filename in contract_files), "-o", str(binary),
        ], timeout=300, check=False)
        contract_record = {
            "sourceSHA": self.args.expected_sha, "sdkRevision": revision,
            "testIdentifier": "Scripts/Tests/verify_chatgpt_plan_contract.swift/VerifyChatGPTPlanContract.main",
            "inputs": {filename: {"path": str(contract_dir / filename), "sha256": digest(contract_dir / filename)} for filename in contract_files},
            "compileExitCode": compile_code, "compileLog": str(compile_log),
            "compileLogSHA256": digest(compile_log), "result": "failed",
        }
        if compile_code == 0:
            run_code, run_log = self.run("plan-contract-execute", [str(binary)], timeout=180, check=False)
            match = re.search(
                r"PASS: (\d+) production SIWC OAuth/wire checks \(macOS CryptoKit/Security fixtures, no live account\)\.",
                run_log.read_text(),
            )
            expected_checks = len(re.findall(r"(?m)^\s*count \+= 1\s*$", (contract_dir / "verify_chatgpt_plan_contract.swift").read_text()))
            contract_record.update({
                "exitCode": run_code, "log": str(run_log), "logSHA256": digest(run_log),
                "binary": str(binary), "binarySHA256": digest(binary),
                "checkCount": int(match[1]) if match else 0, "expectedCheckCount": expected_checks,
                "result": "passed" if run_code == 0 and match and int(match[1]) == expected_checks else "failed",
            })
        self.receipt["sdkPlanContract"] = contract_record
        write_json(self.out / "sdk-plan-contract-receipt.json", contract_record)
        self.save()
        if contract_record["result"] != "passed":
            raise RuntimeError("The original full macOS ChatGPT Plan OAuth/wire contract did not pass.")

    def unit_catalog(self) -> dict:
        # Preserve both the human display label and the original Swift test identifier.
        suite_files = {
            "LorvexAppleTests/MobileTaskWorkspaceTests.swift": "MobileTaskWorkspaceTests",
            "LorvexHanlinAgentTests/LorvexHanlinTaskWorkspaceTests.swift": "LorvexHanlinTaskWorkspaceTests",
            "LorvexHanlinAgentTests/LorvexHanlinAgentTests.swift": "LorvexHanlinAgentTests",
            "LorvexCoreServiceTests/SwiftLorvexCoreServiceInProgressTests.swift": "SwiftLorvexCoreServiceInProgressTests",
            "LorvexHanlinAgentTests/LorvexHanlinPresentationStateTests.swift": "LorvexHanlinPresentationStateTests",
            "LorvexAppleTests/LorvexCloudAccountSyncTests.swift": "LorvexCloudAccountSyncTests",
        }
        function_files = {
            "LorvexAppleTests/AppMetadataTests.swift": "",
            "LorvexAppleTests/NotificationActionsTests.swift": "",
            "LorvexAppleTests/MobileReviewTests.swift": "",
            "LorvexAppleTests/MobileStoreBackgroundAdoptionTests.swift": "",
        }
        catalog = {}
        for relative, suite in {**suite_files, **function_files}.items():
            path = self.apple / "Tests" / relative
            pending = False
            display = None
            for line in path.read_text().splitlines():
                if "@Test" in line:
                    pending = True
                    named = re.search(r'@Test\("([^"]+)"', line)
                    display = named[1] if named else None
                function = re.search(r"\bfunc (\w+)\(", line) if pending else None
                if not function:
                    continue
                pending = False
                if not suite and function[1] not in UNIT_FUNCTIONS:
                    continue
                label = display or function[1] + "()"
                identifier = "/".join(x for x in (relative.split("/")[0], suite, function[1]) if x)
                if label in catalog:
                    raise RuntimeError("Ambiguous native unit case display label: " + label)
                catalog[label] = {
                    "identifier": identifier, "function": function[1],
                    "sourcePath": str(path.relative_to(self.source)), "sourceSHA256": digest(path),
                }
        if len(catalog) != MINIMUM_UNIT_TESTS:
            raise RuntimeError(f"Expected {MINIMUM_UNIT_TESTS} source-declared scoped unit cases, found {len(catalog)}.")
        return catalog

    def units(self):
        catalog = self.unit_catalog()
        code, log = self.run("focused-units", self.unit_command(), timeout=3600, check=False)
        passed = []
        suites = set()
        summary_counts = []
        for raw in log.read_text().splitlines():
            line = re.sub(r"\x1b\[[0-9;]*m", "", raw).strip()
            case = re.match(r"^[✔✓]\ufe0f? Test (?!run with )(.+?) passed after ([0-9.]+) seconds\.", line)
            if case:
                declared = catalog.get(case[1].strip('"'), {})
                passed.append({
                    "name": case[1], "result": "Passed", "durationSeconds": float(case[2]), **declared,
                })
            suite = re.match(r"^[✔✓]\ufe0f? Suite (.+?) passed after ", line)
            if suite:
                suites.add(suite[1].strip('"'))
            summary = re.search(r"Test run with (\d+) tests .*passed", line)
            if summary:
                summary_counts.append(int(summary[1]))
        summary_count = sum(summary_counts)
        missing = [name for name in REQUIRED_UNIT_TESTS if not any(name + "(" in x["name"] for x in passed)]
        xml, xml_cases, xml_sources = unit_xml_evidence(self.out)
        expected_identifiers = {item["identifier"] for item in catalog.values()}
        xml_identifiers = {item["identifier"] for item in xml_cases}
        missing_identifiers = sorted(
            {item["identifier"] for item in catalog.values()}
            - {item.get("identifier") for item in passed}
        )
        accepted = (
            code == 0 and not missing_identifiers and bool(summary_counts) and summary_count == len(passed)
            and len(passed) == MINIMUM_UNIT_TESTS and not missing and UNIT_SUITE_NAMES.issubset(suites)
            and xml_identifiers == expected_identifiers and len(xml_cases) == len(expected_identifiers)
            and not any(case["result"] != "Passed" for case in xml_cases)
        )
        result = {
            "sourceSHA": self.args.expected_sha, "exitCode": code,
            "result": "passed" if accepted else "failed",
            "suites": sorted(suites), "cases": passed, "caseCount": len(passed),
            "summaryCount": summary_count, "missingRequiredTests": missing,
            "missingRequiredSuites": sorted(UNIT_SUITE_NAMES - suites),
            "minimumRequiredCases": MINIMUM_UNIT_TESTS,
            "missingRequiredIdentifiers": missing_identifiers,
            "expectedCaseCatalog": catalog,
            "log": str(log), "logSHA256": digest(log),
            "moduleSummaryCounts": summary_counts,
            "xunitPath": str(xml) if xml else None,
            "xunitSHA256": digest(xml) if xml else None, "xunitCases": xml_cases,
            "xunitSources": xml_sources,
            "missingXMLIdentifiers": sorted(expected_identifiers - xml_identifiers),
            "unexpectedXMLIdentifiers": sorted(xml_identifiers - expected_identifiers),
        }
        self.receipt["unit"] = result
        write_json(self.out / "unit-receipt.json", result)
        self.save()
        if not accepted:
            raise RuntimeError("Focused unit evidence is incomplete or failed; inspect unit-receipt.json and its log.")

    def build(self):
        self.project_dir.mkdir(parents=True, exist_ok=True)
        self.run("xcodegen", [
            "xcodegen", "--spec", str(self.apple / "Config/XcodeGen/project.yml"),
            "--project", str(self.project_dir), "--project-root", str(self.apple), "--quiet",
        ])
        lock = self.project / "project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
        lock.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(self.apple / "Config/XcodeGen/Package.resolved", lock)
        code, log = self.run("native-build-for-testing", self.build_command(), timeout=3600, check=False)
        if code:
            self.receipt["build"] = {"result": "failed", "exitCode": code, "log": str(log)}
            self.save()
            raise RuntimeError("Native build-for-testing failed.")
        products = self.dd / "Build/Products"
        candidates = [
            p for p in products.glob(
                f"{UI_TARGET}_iphonesimulator{self.receipt['simulatorSDK']}-*.xctestrun"
            ) if ".workspace-" not in p.name
        ]
        if len(candidates) != 1:
            raise RuntimeError(f"Expected one original build-produced xctestrun, found {candidates}")
        manifest = candidates[0]
        if not list(targets(plistlib.loads(manifest.read_bytes()))):
            raise RuntimeError("Build-produced xctestrun has no LorvexMobileUITests target.")
        app = products / "Debug-iphonesimulator/LorvexMobileApp.app"
        info = plistlib.loads((app / "Info.plist").read_bytes())
        if info["CFBundleIdentifier"] != "com.itorah.lorvex":
            raise RuntimeError("Unexpected tested application identity.")
        closure = runtime_closure.capture(app, manifest)
        closure_path = self.out / "runtime-binary-closure-build.json"
        write_json(closure_path, closure)
        result = {
            "sourceSHA": self.args.expected_sha, "sourceTree": self.receipt["sourceTree"],
            "result": "passed", "exitCode": code, "log": str(log), "logSHA256": digest(log),
            "xctestrun": str(manifest), "xctestrunSHA256": digest(manifest),
            "application": str(app),
            "productInfo": {key: info.get(key) for key in (
                "CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion",
                "MinimumOSVersion", "DTSDKName", "DTXcodeBuild",
            )},
            "binarySHA256": closure["machOBinaries"],
            "runtimeBinaryClosure": closure,
            "runtimeBinaryClosureArtifact": {"path": str(closure_path), "sha256": digest(closure_path)},
        }
        self.assert_source()
        self.receipt["build"] = result
        write_json(self.out / "build-receipt.json", result)
        self.save()

    def load_build(self) -> dict:
        path = self.args.build_receipt or self.out / "build-receipt.json"
        result = json.loads(path.read_text())
        if result.get("sourceSHA") != self.args.expected_sha or result.get("result") != "passed":
            raise RuntimeError("UI requires a passing build receipt for this exact source SHA.")
        if digest(Path(result["xctestrun"])) != result["xctestrunSHA256"]:
            raise RuntimeError("Original xctestrun changed since its recorded build.")
        for path, expected in result["binarySHA256"].items():
            if digest(Path(path)) != expected:
                raise RuntimeError("Built application binary changed: " + path)
        artifact = result["runtimeBinaryClosureArtifact"]
        closure_path = Path(artifact["path"])
        if digest(closure_path) != artifact["sha256"]:
            raise RuntimeError("Build runtime closure artifact changed.")
        recorded = result["runtimeBinaryClosure"]
        if json.loads(closure_path.read_text()) != recorded:
            raise RuntimeError("Build runtime closure artifact disagrees with its receipt.")
        observed = runtime_closure.capture(Path(result["application"]), Path(result["xctestrun"]))
        if observed != recorded or result["binarySHA256"] != observed["machOBinaries"]:
            raise RuntimeError("Native runtime or XCTest binary closure changed after the build.")
        self.receipt["testedBuildReceipt"] = str(self.args.build_receipt or self.out / "build-receipt.json")
        self.receipt["testedBuildReceiptSHA256"] = digest(Path(self.receipt["testedBuildReceipt"]))
        return result

    def record_runtime_closure(self, record: dict, case_dir: Path, stage: str):
        build = self.load_build()
        path = case_dir / f"runtime-binary-closure-{stage}.json"
        write_json(path, build["runtimeBinaryClosure"])
        record["runtimeBinaryClosure" + stage.title()] = {"path": str(path), "sha256": digest(path)}
        if stage == "after":
            record["runtimeBinaryClosureUnchanged"] = True
        self.save()

    def prepare_system_services(self, key: str, simulator: str, application: str):
        path = Path(__file__).with_name("task_workspace_notification_readiness.py")
        self.receipt["systemServiceReadinessHelper"] = {"path": str(path), "sha256": digest(path)}
        self.save()
        sibling_module("task_workspace_notification_readiness").prepare(self, key, simulator, application)

    def language_manifest(self, original: Path, language: str) -> Path:
        manifest = plistlib.loads(original.read_bytes())
        entries = list(targets(manifest))
        if not entries:
            raise RuntimeError("No UI target to configure in xctestrun.")
        for target in entries:
            target.setdefault("EnvironmentVariables", {}).update({
                "LORVEX_TEST_LANGUAGE": language,
                "LORVEX_TEST_SOURCE_SHA": self.args.expected_sha,
                "LORVEX_TEST_RUN_ID": self.out.name,
            })
            target.setdefault("UITargetAppEnvironmentVariables", {})["LORVEX_CLOUD_SYNC"] = "off"
        # Keep __TESTROOT__ anchored to the original Build/Products directory.
        path = original.with_name(original.stem + ".workspace-" + language + ".xctestrun")
        path.write_bytes(plistlib.dumps(manifest, sort_keys=False))
        return path

    def extract_case(self, record: dict, case_dir: Path):
        result = Path(record["xcresult"])
        summary = self.json_command(record["key"] + "-summary", [
            "xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result),
        ])
        tree = self.json_command(record["key"] + "-tests", [
            "xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(result),
        ])
        write_json(case_dir / "summary.json", summary)
        write_json(case_dir / "tests.json", tree)
        matching = [
            case for case in test_cases(tree.get("testNodes", []))
            if UI_CASE in case.get("nodeIdentifier", "") or (
                case.get("name", "").rstrip("()") == UI_CASE.rsplit("/", 1)[1]
            )
        ]
        record.update({"summary": summary, "testCases": matching})
        attachments = case_dir / "attachments"
        self.run(record["key"] + "-attachments", [
            "xcrun", "xcresulttool", "export", "attachments",
            "--path", str(result), "--output-path", str(attachments),
        ])
        manifest = json.loads((attachments / "manifest.json").read_text())
        record["attachmentManifestSHA256"] = digest(attachments / "manifest.json")
        exports = []
        screenshots = {}
        proof = None
        prefix = f"Lorvex {record['language']} - "
        for test in manifest:
            for attachment in test.get("attachments", []):
                path = (attachments / attachment["exportedFileName"]).resolve()
                if not path.is_relative_to(attachments.resolve()) or not path.is_file():
                    raise RuntimeError("Invalid exported attachment path.")
                label = attachment["suggestedHumanReadableName"]
                item = {**attachment, "testIdentifier": test["testIdentifier"],
                        "path": str(path), "sha256": digest(path), "size": path.stat().st_size}
                exports.append(item)
                if label.startswith(prefix + "workspace persistence receipt"):
                    proof = json.loads(path.read_text())
                    record["persistenceAttachment"] = item
                for mode in MODES:
                    if label.startswith(prefix + f"live {mode} with connected real tasks") and path.suffix.lower() == ".png":
                        representative = self.out / "screenshots" / f"{record['key']}-{mode}.png"
                        representative.parent.mkdir(exist_ok=True)
                        shutil.copyfile(path, representative)
                        screenshots[mode] = {
                            "path": str(representative), "sha256": digest(representative),
                            "originalAttachment": item,
                        }
        write_json(case_dir / "attachments-index.json", exports)
        record["screenshots"] = screenshots
        record["persistenceProof"] = proof
        proof_ok = bool(proof) and (
            proof.get("sourceSHA") == self.args.expected_sha
            and proof.get("language") == record["language"]
            and proof.get("taskID") and proof.get("prerequisiteID")
            and proof["taskID"] != proof["prerequisiteID"]
            and proof.get("restartObserved") is True
            and proof.get("completedAfterRelaunch") is True
            and proof.get("dueDatePreservedAfterRelaunch") is True
            and proof.get("reopenedInCanonicalDetail") is True
        )
        record["appRestartPersistenceVerified"] = bool(proof_ok)
        record["result"] = "passed" if (
            record["exitCode"] == 0 and summary.get("result") == "Passed"
            and summary.get("passedTests") == 1 and summary.get("failedTests") == 0
            and summary.get("skippedTests") == 0 and len(matching) == 1
            and matching[0].get("result") == "Passed" and set(screenshots) == set(MODES)
            and proof_ok
        ) else "failed"

    def simulator_inventory(self):
        runtimes = self.json_command("simulator-runtimes", ["xcrun", "simctl", "list", "runtimes", "-j"])
        types = self.json_command("simulator-device-types", ["xcrun", "simctl", "list", "devicetypes", "-j"])
        runtime = next((
            x for x in runtimes["runtimes"] if x["identifier"] == self.args.runtime
            and x.get("isAvailable") and not x.get("isInternal") and x.get("platform") == "iOS"
        ), None)
        if not runtime:
            raise RuntimeError("Requested noninternal iOS runtime is unavailable.")
        supported = {x["identifier"] for x in runtime.get("supportedDeviceTypes", [])}
        installed = {x["identifier"] for x in types["devicetypes"]}
        if not set(DEVICE_TYPES.values()).issubset(supported & installed):
            raise RuntimeError("Requested runtime does not support both installed test device types.")
        self.receipt["simulatorInventory"] = {"runtime": runtime, "deviceTypes": DEVICE_TYPES}

    def ui(self):
        build = self.load_build()
        self.simulator_inventory()
        original = Path(build["xctestrun"])
        manifests = {language: self.language_manifest(original, language) for language in ("en", "he")}
        for key in self.args.cases:
            family, language = key.split("-")
            case_dir = self.out / key
            case_dir.mkdir()
            record = {
                "key": key, "sourceSHA": self.args.expected_sha, "startedUTC": utc(),
                "family": family, "language": language, "region": "IL" if language == "he" else "US",
                "runtime": self.args.runtime, "deviceType": DEVICE_TYPES[family],
                "selector": UI_SELECTOR, "result": "running",
                "xctestrun": str(manifests[language]), "xctestrunSHA256": digest(manifests[language]),
                "xcresult": str(case_dir / "result.xcresult"),
                "freshSimulator": True, "appRestartPersistenceVerified": False,
            }
            self.receipt["cases"].append(record)
            self.save()
            simulator = None
            try:
                _, log = self.run(key + "-create", [
                    "xcrun", "simctl", "create",
                    f"Lorvex-visual-{key}-{self.args.expected_sha[:8]}-{uuid.uuid4().hex[:6]}",
                    DEVICE_TYPES[family], self.args.runtime,
                ])
                simulator = log.read_text().strip()
                uuid.UUID(simulator)  # Never target an unvalidated or preexisting identifier.
                record["simulatorID"] = simulator
                self.save()
                self.run(key + "-boot", ["xcrun", "simctl", "boot", simulator])
                self.run(key + "-bootstatus", ["xcrun", "simctl", "bootstatus", simulator, "-b"], timeout=180)
                self.record_runtime_closure(record, case_dir, "before")
                self.prepare_system_services(key, simulator, build["application"])
                code, log = self.run(
                    key + "-test", self.ui_command(manifests[language], simulator, language, Path(record["xcresult"])),
                    timeout=900, check=False,
                )
                record.update({"exitCode": code, "log": str(log), "logSHA256": digest(log)})
                if Path(record["xcresult"]).is_dir():
                    self.extract_case(record, case_dir)
                else:
                    record["result"] = "failed"
                    record["error"] = "No xcresult was produced."
            except BaseException as error:
                record["result"] = "failed"
                record["error"] = str(error)
                raise
            finally:
                if simulator:
                    self.run(key + "-shutdown", ["xcrun", "simctl", "shutdown", simulator], check=False)
                try:
                    self.record_runtime_closure(record, case_dir, "after")
                except Exception as error:
                    record.update(result="failed", error=str(error), runtimeBinaryClosureUnchanged=False)
                if simulator:
                    if record["result"] == "passed":
                        code, _ = self.run(key + "-delete", ["xcrun", "simctl", "delete", simulator], check=False)
                        record["simulatorDeleted"] = code == 0
                    else:
                        record["simulatorPreservedForDebugging"] = True
                record["finishedUTC"] = utc()
                write_json(case_dir / "case-receipt.json", record)
                self.save()
                self.publish_screenshots()
            if record["result"] != "passed":
                raise RuntimeError(f"{key} failed; remaining configurations were not run.")
    def extract_host_ui(self, record: dict, case_dir: Path):
        result = Path(record["xcresult"])
        summary = self.json_command("hanlin-host-summary", [
            "xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result),
        ])
        tree = self.json_command("hanlin-host-tests", [
            "xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(result),
        ])
        write_json(case_dir / "summary.json", summary)
        write_json(case_dir / "tests.json", tree)
        cases = list(test_cases(tree.get("testNodes", [])))
        matched = {
            expected: [
                case for case in cases
                if case.get("nodeIdentifier", "").removesuffix("()") in (
                    expected, UI_TARGET + "/" + expected,
                )
            ] for expected in HOST_UI_CASES
        }
        record.update({"summary": summary, "matchedCases": matched})
        attachments = case_dir / "attachments"
        self.run("hanlin-host-attachments", [
            "xcrun", "xcresulttool", "export", "attachments",
            "--path", str(result), "--output-path", str(attachments),
        ])
        manifest_path = attachments / "manifest.json"
        manifest = json.loads(manifest_path.read_text())
        record["attachmentManifestSHA256"] = digest(manifest_path)
        exports = []
        screenshots = []
        for test in manifest:
            for attachment in test.get("attachments", []):
                path = (attachments / attachment["exportedFileName"]).resolve()
                if not path.is_relative_to(attachments.resolve()) or not path.is_file():
                    raise RuntimeError("Invalid exported host attachment path.")
                item = {**attachment, "testIdentifier": test["testIdentifier"],
                        "path": str(path), "sha256": digest(path), "size": path.stat().st_size}
                exports.append(item)
                label = attachment.get("suggestedHumanReadableName", "")
                if path.suffix.lower() == ".png" and label.startswith("Lorvex - "):
                    slug = re.sub(r"[^a-z0-9]+", "-", label.lower()).strip("-")[:90]
                    representative = self.out / "screenshots" / ("host-ipad-" + slug + ".png")
                    representative.parent.mkdir(exist_ok=True)
                    shutil.copyfile(path, representative)
                    screenshots.append({
                        "label": label, "path": str(representative),
                        "sha256": digest(representative), "originalAttachment": item,
                    })
        write_json(case_dir / "attachments-index.json", exports)
        record["screenshots"] = screenshots
        record["result"] = "passed" if (
            record["exitCode"] == 0 and summary.get("result") == "Passed"
            and summary.get("passedTests") == len(HOST_UI_CASES)
            and summary.get("failedTests") == 0 and summary.get("skippedTests") == 0
            and len(cases) == len(HOST_UI_CASES)
            and all(len(matches) == 1 and matches[0].get("result") == "Passed"
                    for matches in matched.values())
        ) else "failed"

    def host_ui(self):
        build = self.load_build()
        if "simulatorInventory" not in self.receipt:
            self.simulator_inventory()
        manifest = self.language_manifest(Path(build["xctestrun"]), "en")
        key = "hanlin-host-ipad"
        case_dir = self.out / key
        case_dir.mkdir()
        record = {
            "key": key, "sourceSHA": self.args.expected_sha, "startedUTC": utc(),
            "family": "ipad", "languages": ["en", "he"],
            "runtime": self.args.runtime, "deviceType": DEVICE_TYPES["ipad"],
            "selectors": list(HOST_UI_SELECTORS), "result": "running",
            "xctestrun": str(manifest), "xctestrunSHA256": digest(manifest),
            "xcresult": str(case_dir / "result.xcresult"), "freshSimulator": True,
        }
        self.receipt["hostUI"] = record
        self.save()
        simulator = None
        try:
            _, log = self.run(key + "-create", [
                "xcrun", "simctl", "create",
                f"Lorvex-host-ipad-{self.args.expected_sha[:8]}-{uuid.uuid4().hex[:6]}",
                DEVICE_TYPES["ipad"], self.args.runtime,
            ])
            simulator = log.read_text().strip()
            uuid.UUID(simulator)
            record["simulatorID"] = simulator
            self.save()
            self.run(key + "-boot", ["xcrun", "simctl", "boot", simulator])
            self.run(key + "-bootstatus", ["xcrun", "simctl", "bootstatus", simulator, "-b"], timeout=180)
            self.record_runtime_closure(record, case_dir, "before")
            self.prepare_system_services(key, simulator, build["application"])
            code, log = self.run(
                key + "-test", self.ui_command(
                    manifest, simulator, "en", Path(record["xcresult"]), HOST_UI_SELECTORS,
                ), timeout=1200, check=False,
            )
            record.update({"exitCode": code, "log": str(log), "logSHA256": digest(log)})
            if Path(record["xcresult"]).is_dir():
                self.extract_host_ui(record, case_dir)
            else:
                record.update({"result": "failed", "error": "No xcresult was produced."})
        except BaseException as error:
            record.update({"result": "failed", "error": str(error)})
            raise
        finally:
            if simulator:
                self.run(key + "-shutdown", ["xcrun", "simctl", "shutdown", simulator], check=False)
            try:
                self.record_runtime_closure(record, case_dir, "after")
            except Exception as error:
                record.update(result="failed", error=str(error), runtimeBinaryClosureUnchanged=False)
            if simulator:
                if record["result"] == "passed":
                    code, _ = self.run(key + "-delete", ["xcrun", "simctl", "delete", simulator], check=False)
                    record["simulatorDeleted"] = code == 0
                else:
                    record["simulatorPreservedForDebugging"] = True
            record["finishedUTC"] = utc()
            write_json(case_dir / "case-receipt.json", record)
            write_json(self.out / "host-representative-screenshots.json", record.get("screenshots", []))
            self.save()
        if record["result"] != "passed":
            raise RuntimeError("Required Hanlin host UI acceptance failed; inspect its exact case receipt.")

    def publish_screenshots(self):
        screenshots = [
            {"case": case["key"], "language": case["language"], "family": case["family"],
             "mode": mode, **item}
            for case in self.receipt["cases"] for mode, item in case.get("screenshots", {}).items()
        ]
        write_json(self.out / "representative-screenshots.json", screenshots)

    def execute(self) -> int:
        if sys.platform != "darwin":
            raise RuntimeError("Native validation must execute on the coordinated Apple runner.")
        if self.out.is_relative_to(self.source) or self.dd.is_relative_to(self.source):
            raise RuntimeError("Evidence and DerivedData must remain outside the exact source checkout.")
        if self.out.exists():
            raise RuntimeError("Output already exists; use a unique evidence directory to preserve prior results.")
        self.assert_source()
        self.out.mkdir(parents=True)
        self.dd.mkdir(parents=True, exist_ok=True)
        self.save()
        with (self.dd / ".lorvex-task-workspace-validation.lock").open("a+") as lock:
            try:
                fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                self.receipt.update({
                    "result": "failed", "finishedUTC": utc(),
                    "error": "Another Lorvex validation owns this DerivedData directory.",
                })
                self.save()
                raise RuntimeError(self.receipt["error"])
            lock.seek(0)
            lock.truncate()
            lock.write(json.dumps({"pid": os.getpid(), "sourceSHA": self.args.expected_sha, "startedUTC": utc()}))
            lock.flush()
            try:
                self.preflight()
                if self.args.phase in ("unit", "all"):
                    self.sdk_plan_acceptance()
                    self.units()
                if self.args.phase in ("build", "all"):
                    self.build()
                if self.args.phase in ("ui", "all"):
                    self.ui()
                if self.args.phase in ("ui", "host-ui", "all"):
                    self.host_ui()
                self.assert_source()
                self.receipt["trackedSourceCleanAfter"] = True
                self.receipt["result"] = "passed"
            except BaseException as error:
                self.receipt["result"] = "failed"
                self.receipt["error"] = str(error)
                self.receipt["trackedSourceCleanAfter"] = not bool(self.raw_git("status", "--porcelain"))
            finally:
                self.receipt["finishedUTC"] = utc()
                self.receipt["matrixComplete"] = {
                    case["key"] for case in self.receipt["cases"] if case["result"] == "passed"
                } == set(MATRIX)
                self.receipt["requiredHostUIComplete"] = self.receipt.get("hostUI", {}).get("result") == "passed"
                self.save()
        print(json.dumps({
            "result": self.receipt["result"], "receipt": str(self.out / "receipt.json"),
            "matrixComplete": self.receipt["matrixComplete"],
        }), flush=True)
        return 0 if self.receipt["result"] == "passed" else 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=Path(__file__).resolve().parents[3])
    parser.add_argument("--expected-sha", required=True)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--derived-data", required=True, type=Path)
    parser.add_argument("--source-packages", type=Path)
    parser.add_argument("--kit-mirror", type=Path)
    parser.add_argument("--developer-dir", type=Path)
    parser.add_argument("--ui-developer-dir", type=Path, help="Per-process simulator/test driver, separate from the compiler.")
    parser.add_argument("--plan-harness", type=Path, help="Existing original SDK test harness; required for executing unit/all phases.")
    parser.add_argument("--runtime", default="com.apple.CoreSimulator.SimRuntime.iOS-27-2")
    parser.add_argument("--phase", choices=("unit", "build", "ui", "host-ui", "all"), default="all")
    parser.add_argument("--build-receipt", type=Path, help="Reuse a verified build for this exact SHA during --phase ui or host-ui.")
    parser.add_argument("--cases", default=",".join(MATRIX), help="Comma-separated focused UI cases; default is the four-case matrix.")
    parser.add_argument("--execute", action="store_true", help="Execute only after the coordinator explicitly grants the heavy Mac slot.")
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-f]{40}", args.expected_sha):
        parser.error("--expected-sha must be a full immutable commit.")
    args.cases = args.cases.split(",")
    if not args.cases or len(set(args.cases)) != len(args.cases) or not set(args.cases).issubset(MATRIX):
        parser.error("--cases must select distinct iphone-en, iphone-he, ipad-en, ipad-he entries.")
    controller = Controller(args)
    if not args.execute:
        print(json.dumps(controller.plan(), indent=2))
        return 0
    return controller.execute()


if __name__ == "__main__":
    raise SystemExit(main())
