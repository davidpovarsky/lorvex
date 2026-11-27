#!/usr/bin/env python3
"""Bind Timeline zoom to XCTest's actual two-finger input, not its nominal request.

XCTest documents pinch scale as best effort. The original 5095da18 result sent
a 2.659x distance change for a nominal 1.25x request; the app returned 2.613x.
Acceptance requires the full original UI test to pass and independent raw input
agreement within 10%. Missing/discarded events fail closed. Run manifests must
set SystemAttachmentLifetime=keepAlways.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import math
from pathlib import Path
import plistlib
import subprocess

TEST_ID = "TaskWorkspaceInteractionIntegrationTests/testRealZoomAndBoardActionsPreserveCanonicalTasks()"
OBSERVATION = "Lorvex Timeline pinch measured output"
RELATIVE_TOLERANCE = 0.10


def decode_event(payload: bytes) -> dict:
    archive = plistlib.loads(payload)
    if archive.get("$archiver") != "NSKeyedArchiver":
        raise ValueError("Expected an original NSKeyedArchiver event")
    objects = archive["$objects"]

    def decode(value, stack=()):
        if isinstance(value, plistlib.UID):
            index = value.data
            if index in stack or not 0 <= index < len(objects):
                raise ValueError("Invalid or cyclic event reference")
            return decode(objects[index], (*stack, index))
        if isinstance(value, list):
            return [decode(item, stack) for item in value]
        if isinstance(value, dict):
            if "NS.objects" in value:
                values = decode(value["NS.objects"], stack)
                if "NS.keys" in value:
                    return dict(zip(decode(value["NS.keys"], stack), values))
                return values
            return {key: decode(item, stack) for key, item in value.items() if key != "$class"}
        return value

    return decode(archive["$top"]["root"])


def compare(event: dict, observed: dict) -> dict:
    if event.get("name") != "pinch":
        raise ValueError("Input is not a pinch")
    paths = event.get("eventPaths", [])
    if len(paths) != 2:
        raise ValueError("Exactly two original finger paths are required")
    fingers = [path["pointerEvents"] for path in paths]
    if any(len(finger) < 3 for finger in fingers):
        raise ValueError("Incomplete two-finger input")
    for finger in fingers:
        if finger[0]["eventType"] != 1 or finger[-1]["eventType"] != 3:
            raise ValueError("Each finger must have its original down and up")
        offsets = [point["offset"] for point in finger]
        values = offsets + [point[key] for point in finger for key in ("coordinate.x", "coordinate.y")]
        if not all(isinstance(value, (int, float)) and math.isfinite(value) for value in values):
            raise ValueError("Non-finite input coordinates")
        if offsets[0] != 0 or offsets[-1] <= 0 or offsets != sorted(offsets):
            raise ValueError("Invalid finger chronology")
    if not math.isclose(fingers[0][-1]["offset"], fingers[1][-1]["offset"], abs_tol=0.001):
        raise ValueError("Finger paths do not belong to one synchronized gesture")

    def distance(index):
        first, second = (finger[index] for finger in fingers)
        return math.hypot(first["coordinate.x"] - second["coordinate.x"],
                          first["coordinate.y"] - second["coordinate.y"])

    initial, final = distance(0), distance(-1)
    if initial <= 0 or final <= initial * 1.05:
        raise ValueError("Input did not deliver an opening pinch")
    if observed.get("schemaVersion") != 1 or observed.get("requestedScale") != 1.25 or observed.get("requestedVelocity") != 0.6:
        raise ValueError("Observation does not bind the original requested gesture")
    before, after = observed["beforePercent"], observed["afterPercent"]
    if not all(isinstance(v, (int, float)) and math.isfinite(v) and v > 0 for v in (before, after)):
        raise ValueError("Invalid observed zoom")
    factor = final / initial
    expected = before * factor
    if expected >= 1600:
        raise ValueError("Clamped gesture cannot prove proportional zoom")
    error = (after / expected) - 1
    if after <= before * 1.05 or after > 1600 or abs(error) > RELATIVE_TOLERANCE:
        raise ValueError(f"Rendered zoom disagrees with raw touch input: relative error {error:.6f}")
    return {
        "initialFingerDistance": initial, "finalFingerDistance": final,
        "deliveredFactor": factor, "beforePercent": before, "afterPercent": after,
        "expectedAfterPercent": expected, "relativeError": error,
        "maximumRelativeError": RELATIVE_TOLERANCE,
    }


def walk(value):
    if isinstance(value, dict):
        yield value
        for item in value.values():
            yield from walk(item)
    elif isinstance(value, list):
        for item in value:
            yield from walk(item)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def validate(result: Path, output: Path) -> dict:
    output.mkdir(parents=True, exist_ok=True)

    def command(*args):
        return subprocess.check_output(["xcrun", "xcresulttool", *args], text=True)

    tests_text = command("get", "test-results", "tests", "--path", str(result))
    (output / "original-test-results.json").write_text(tests_text)
    tests = [node for node in walk(json.loads(tests_text))
             if node.get("nodeType") == "Test Case"
             and node.get("nodeIdentifier") == TEST_ID]
    if len(tests) != 1 or tests[0].get("result") != "Passed":
        raise ValueError("The complete original interaction test must pass exactly once")
    activities_text = command("get", "test-results", "activities", "--path", str(result), "--test-id", TEST_ID)
    (output / "original-activities.json").write_text(activities_text)
    activities = json.loads(activities_text)
    pinches = [node for node in walk(activities)
               if node.get("title", "").startswith("Pinch with scale 1.25, velocity 0.6 in ")
               and '"task-workspace.timeline.chart"' in node["title"]]
    if len(pinches) != 1:
        raise ValueError("Exactly one original Timeline pinch activity is required")
    events = {attachment["payloadId"]: attachment for node in walk(pinches[0])
              for attachment in node.get("attachments", [])
              if attachment.get("name", "").startswith("Synthesized Event ")}
    observations = {attachment["payloadId"]: attachment for node in walk(activities)
                    for attachment in node.get("attachments", [])
                    if attachment.get("name", "").startswith(OBSERVATION)}
    if len(events) != 1 or len(observations) != 1:
        raise ValueError("Original synthesized event and numeric observation must both be retained")

    def export(attachments, name):
        payload, metadata = next(iter(attachments.items()))
        path = output / name
        if path.exists():
            raise ValueError(f"Output already exists: {name}")
        command("export", "object", "--legacy", "--path", str(result),
                "--id", payload, "--type", "file", "--output-path", str(path))
        return path, {"path": str(path), "sha256": sha(path), "payloadId": payload,
                      "timestamp": metadata.get("timestamp")}

    event_path, event_meta = export(events, "original-synthesized-event.plist")
    observed_path, observed_meta = export(observations, "original-observed-zoom.json")
    if not isinstance(event_meta["timestamp"], (int, float)) or not isinstance(observed_meta["timestamp"], (int, float)):
        raise ValueError("Missing original activity timestamps")
    if not 0 <= observed_meta["timestamp"] - event_meta["timestamp"] <= 30:
        raise ValueError("Zoom observation is not immediately after the original gesture")
    comparison = compare(decode_event(event_path.read_bytes()), json.loads(observed_path.read_text()))
    return {
        "schemaVersion": 1, "result": "passed", "testIdentifier": TEST_ID,
        "xcresult": str(result.resolve()), "validatorSHA256": sha(Path(__file__).resolve()),
        "input": event_meta, "observation": observed_meta,
        "testsSHA256": sha(output / "original-test-results.json"),
        "activitiesSHA256": sha(output / "original-activities.json"), **comparison,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--xcresult", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    receipt = validate(args.xcresult, args.output)
    (args.output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt))


if __name__ == "__main__":
    main()
