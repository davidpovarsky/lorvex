#!/usr/bin/env bash
# One focused acceptance test in the actual Lorvex iPad app. Runs headlessly.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$ROOT/dist/hanlin-ios-xcode-project"
OUT="$ROOT/dist/hanlin-host-ui"
mkdir -p "$PROJECT_DIR" "$OUT"
python3 "$ROOT/script/install_hanlin_sdk.py" --check > "$OUT/sdk-installation.json"
xcodegen --spec "$ROOT/Config/XcodeGen/project.yml"   --project "$PROJECT_DIR" --project-root "$ROOT" --quiet
SIMULATOR_ID="$(python3 - <<'PY'
import json,subprocess,uuid
runtimes=json.loads(subprocess.check_output(["xcrun","simctl","list","runtimes","-j"]))["runtimes"]
runtimes=[r for r in runtimes if r.get("isAvailable") and "iOS" in r["name"] and r.get("version", "").split(".")[0] == "27"]
if not runtimes: raise SystemExit("iOS 27 Simulator runtime is required for the real-host UI acceptance test")
runtime=sorted(runtimes,key=lambda r: tuple(int(p) for p in r["version"].split(".")))[-1]
types=json.loads(subprocess.check_output(["xcrun","simctl","list","devicetypes","-j"]))["devicetypes"]
types=[d for d in types if "iPad Pro" in d["name"]]
if not types: raise SystemExit("An iPad Simulator device type is required")
device=next((d for d in reversed(types) if "13-inch" in d["name"]),types[-1])
print(subprocess.check_output(["xcrun","simctl","create","Lorvex-Hanlin-"+uuid.uuid4().hex[:8],device["identifier"],runtime["identifier"]],text=True).strip())
PY
)"
cleanup() {
  xcrun simctl shutdown "$SIMULATOR_ID" >/dev/null 2>&1 || true
  xcrun simctl delete "$SIMULATOR_ID" >/dev/null 2>&1 || true
}
trap cleanup EXIT
printf '%s\n' "$SIMULATOR_ID" > "$OUT/simulator-id.txt"
xcrun simctl boot "$SIMULATOR_ID"
xcrun simctl bootstatus "$SIMULATOR_ID" -b
status=0
# Use the same noninteractive macro enablement as the actual device build.
xcodebuild -project "$PROJECT_DIR/LorvexAppleNative.xcodeproj" \
  -scheme LorvexMobileUITests -configuration Debug \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -derivedDataPath "$ROOT/dist/hanlin-ipad-simulator" \
  -clonedSourcePackagesDirPath "$ROOT/dist/hanlin-ipad-build/SourcePackages" \
  -resultBundlePath "$OUT/Lorvex-Hanlin-UI.xcresult" \
  -parallel-testing-enabled NO -skipMacroValidation \
  -only-testing:LorvexMobileUITests/HanlinSDKIntegrationTests/testOriginalComposerInsideLorvex \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- \
  test 2>&1 | tee "$OUT/lorvex-hanlin-ui.log" || status=$?
if [[ -d "$OUT/Lorvex-Hanlin-UI.xcresult" ]]; then
  xcrun xcresulttool export attachments --path "$OUT/Lorvex-Hanlin-UI.xcresult"     --output-path "$OUT/screenshots" || true
fi
exit "$status"
