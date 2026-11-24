#!/usr/bin/env bash
# Focused acceptance tests in the actual Lorvex iPad app. Runs headlessly.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$ROOT/dist/hanlin-ios-xcode-project"
OUT="${LORVEX_UI_OUTPUT_DIR:-$ROOT/dist/hanlin-host-ui}"
DERIVED_DATA="${LORVEX_UI_DERIVED_DATA:-$ROOT/dist/hanlin-ipad-simulator}"
SOURCE_PACKAGES="${LORVEX_UI_SOURCE_PACKAGES:-$ROOT/dist/hanlin-ipad-build/SourcePackages}"
mkdir -p "$PROJECT_DIR" "$OUT"
source "$ROOT/script/lib_xcode_package_lock.sh"
python3 "$ROOT/script/install_hanlin_sdk.py" --check > "$OUT/sdk-installation.json"
# Default to the immutable SDK's stable-build picker. A routed Mac may explicitly
# use a newer compiler and a separately verified XCTest runner. Never change the
# host's global xcode-select setting or silently substitute a simulator runtime.
if [[ -z "${LORVEX_UI_BUILD_DEVELOPER_DIR:-}" ]]; then
  SDK_ROOT="$ROOT/../../Vendor/HanlinSDK"
  git -C "$SDK_ROOT" show HEAD:Scripts/CI/select_stable_xcode.py > "$OUT/select_stable_xcode.py"
  XCODE_APP="$(python3 "$OUT/select_stable_xcode.py")"
  LORVEX_UI_BUILD_DEVELOPER_DIR="$XCODE_APP/Contents/Developer"
fi
export LORVEX_UI_BUILD_DEVELOPER_DIR
export LORVEX_UI_TEST_DEVELOPER_DIR="${LORVEX_UI_TEST_DEVELOPER_DIR:-$LORVEX_UI_BUILD_DEVELOPER_DIR}"
[[ -d "$LORVEX_UI_BUILD_DEVELOPER_DIR" && -d "$LORVEX_UI_TEST_DEVELOPER_DIR" ]] || {
  echo "Both explicitly selected Xcode developer directories must exist." >&2
  exit 1
}
export DEVELOPER_DIR="$LORVEX_UI_BUILD_DEVELOPER_DIR"
xcodebuild -version > "$OUT/xcode-build-version.txt"
DEVELOPER_DIR="$LORVEX_UI_TEST_DEVELOPER_DIR" xcodebuild -version > "$OUT/xcode-test-version.txt"
xcodegen --spec "$ROOT/Config/XcodeGen/project.yml" --project "$PROJECT_DIR" --project-root "$ROOT" --quiet
seed_xcode_package_lock "$ROOT" "$PROJECT_DIR/LorvexAppleNative.xcodeproj"
SIMULATOR_ID="$(python3 - "$OUT" <<'PY'
import json,os,pathlib,subprocess,sys,uuid
sdk=subprocess.check_output(["xcrun","--sdk","iphonesimulator","--show-sdk-version"],text=True).strip()
if sdk.split(".")[0] != "27":
    raise SystemExit("The installed stable iOS 27 SDK is required for the real-host UI acceptance test")
test_env={**os.environ,"DEVELOPER_DIR":os.environ["LORVEX_UI_TEST_DEVELOPER_DIR"]}
def simctl(*args):
    return subprocess.check_output(["xcrun","simctl",*args],env=test_env,text=True)
runtimes=json.loads(simctl("list","runtimes","-j"))["runtimes"]
installed_types=json.loads(simctl("list","devicetypes","-j"))["devicetypes"]
runtime_id=os.environ.get("LORVEX_UI_RUNTIME_ID","com.apple.CoreSimulator.SimRuntime.iOS-"+sdk.replace(".","-"))
(pathlib.Path(sys.argv[1])/"simulator-inventory.json").write_text(json.dumps(
    {"sdkVersion":sdk,"requestedRuntimeID":runtime_id,"runtimes":runtimes,"installedDeviceTypes":installed_types},indent=2)+"\n")
runtime=next((r for r in runtimes if r.get("isAvailable") and not r.get("isInternal")
    and r["identifier"]==runtime_id and r.get("platform")=="iOS"
    and r["version"].split(".")[0]=="27"),None)
if runtime is None:
    raise SystemExit("The explicitly selected stable iOS 27 Simulator runtime is unavailable: "+runtime_id)
installed_ids={d["identifier"] for d in installed_types}
# Runtime metadata owns hardware compatibility and family.
types=[d for d in runtime.get("supportedDeviceTypes",[]) if "iPad Pro" in d["name"]
    and d["identifier"] in installed_ids]
if not types:
    raise SystemExit("The selected iOS 27 runtime has no compatible iPad Pro Simulator device type")
device=next((d for d in reversed(types) if "13-inch" in d["name"]),types[-1])
(pathlib.Path(sys.argv[1])/"simulator-selection.json").write_text(json.dumps(
    {"sdkVersion":sdk,"buildDeveloperDir":os.environ["LORVEX_UI_BUILD_DEVELOPER_DIR"],
     "testDeveloperDir":os.environ["LORVEX_UI_TEST_DEVELOPER_DIR"],
     "runtime":runtime,"device":device},indent=2)+"\n")
print(simctl("create","Lorvex-Hanlin-"+uuid.uuid4().hex[:8],device["identifier"],runtime["identifier"]).strip())
PY
)"
cleanup() {
  DEVELOPER_DIR="$LORVEX_UI_TEST_DEVELOPER_DIR" xcrun simctl shutdown "$SIMULATOR_ID" >/dev/null 2>&1 || true
  DEVELOPER_DIR="$LORVEX_UI_TEST_DEVELOPER_DIR" xcrun simctl delete "$SIMULATOR_ID" >/dev/null 2>&1 || true
}
trap cleanup EXIT
printf '%s\n' "$SIMULATOR_ID" > "$OUT/simulator-id.txt"
# Compile once with the selected compiler, then execute those exact products.
# This also avoids booting another simulator while compilation is in progress.
xcodebuild -project "$PROJECT_DIR/LorvexAppleNative.xcodeproj" \
  -scheme LorvexMobileUITests -configuration Debug -jobs "${LORVEX_UI_JOBS:-3}" \
  -destination "generic/platform=iOS Simulator" \
  -derivedDataPath "$DERIVED_DATA" \
  -clonedSourcePackagesDirPath "$SOURCE_PACKAGES" \
  "${XCODE_PINNED_RESOLUTION_FLAGS[@]}" \
  -parallel-testing-enabled NO -skipMacroValidation \
  -only-testing:LorvexMobileUITests/HanlinSDKIntegrationTests \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- \
  build-for-testing 2>&1 | tee "$OUT/lorvex-hanlin-ui-build.log"
export DEVELOPER_DIR="$LORVEX_UI_TEST_DEVELOPER_DIR"
xcrun simctl boot "$SIMULATOR_ID"
xcrun simctl bootstatus "$SIMULATOR_ID" -b
status=0
xcodebuild -project "$PROJECT_DIR/LorvexAppleNative.xcodeproj" \
  -scheme LorvexMobileUITests -configuration Debug -jobs "${LORVEX_UI_JOBS:-3}" \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -derivedDataPath "$DERIVED_DATA" \
  -clonedSourcePackagesDirPath "$SOURCE_PACKAGES" \
  "${XCODE_PINNED_RESOLUTION_FLAGS[@]}" \
  -resultBundlePath "$OUT/Lorvex-Hanlin-UI.xcresult" \
  -parallel-testing-enabled NO -skipMacroValidation \
  -only-testing:LorvexMobileUITests/HanlinSDKIntegrationTests \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- \
  test-without-building 2>&1 | tee "$OUT/lorvex-hanlin-ui.log" || status=$?
if [[ -d "$OUT/Lorvex-Hanlin-UI.xcresult" ]]; then
  xcrun xcresulttool export attachments --path "$OUT/Lorvex-Hanlin-UI.xcresult" --output-path "$OUT/screenshots" || true
fi
exit "$status"
