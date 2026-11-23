#!/usr/bin/env bash
# One focused acceptance test in the actual Lorvex iPad app. Runs headlessly.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$ROOT/dist/hanlin-ios-xcode-project"
OUT="$ROOT/dist/hanlin-host-ui"
mkdir -p "$PROJECT_DIR" "$OUT"
python3 "$ROOT/script/install_hanlin_sdk.py" --check > "$OUT/sdk-installation.json"
xcodegen --spec "$ROOT/Config/XcodeGen/project.yml"   --project "$PROJECT_DIR" --project-root "$ROOT" --quiet
SIMULATOR_ID="$(python3 - "$OUT" <<'PY'
import json,pathlib,subprocess,sys,uuid
sdk=subprocess.check_output(["xcrun","--sdk","iphonesimulator","--show-sdk-version"],text=True).strip()
if sdk.split(".")[0] != "27":
    raise SystemExit("The installed stable iOS 27 SDK is required for the real-host UI acceptance test")
runtimes=json.loads(subprocess.check_output(["xcrun","simctl","list","runtimes","-j"]))["runtimes"]
installed_types=json.loads(subprocess.check_output(["xcrun","simctl","list","devicetypes","-j"]))["devicetypes"]
(pathlib.Path(sys.argv[1])/"simulator-inventory.json").write_text(json.dumps(
    {"sdkVersion":sdk,"runtimes":runtimes,"installedDeviceTypes":installed_types},indent=2)+"\n")
runtime=next((r for r in runtimes if r.get("isAvailable") and not r.get("isInternal")
    and r["identifier"].endswith("iOS-"+sdk.replace(".","-"))),None)
if runtime is None:
    raise SystemExit("An available stable Simulator runtime matching the installed iOS 27 SDK is required")
installed_ids={d["identifier"] for d in installed_types}
# Runtime metadata owns hardware compatibility and family. The global device
# inventory is only an installation cross-check; its rows need not carry family.
types=[d for d in runtime.get("supportedDeviceTypes",[]) if "iPad Pro" in d["name"]
    and d["identifier"] in installed_ids]
if not types:
    raise SystemExit("The selected iOS 27 runtime has no compatible iPad Pro Simulator device type")
device=next((d for d in reversed(types) if "13-inch" in d["name"]),types[-1])
(pathlib.Path(sys.argv[1])/"simulator-selection.json").write_text(json.dumps(
    {"sdkVersion":sdk,"runtime":runtime,"device":device},indent=2)+"\n")
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
