#!/usr/bin/env bash
# Builds a real iPadOS arm64 application and exports a zip-format UNSIGNED IPA.
# For an installable IPA, authorized Apple Developer signing/provisioning is
# mandatory. See script/archive_ios.sh --export for the signed Apple flow.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$ROOT/dist/hanlin-ios-xcode-project"
BUILD_DIR="$ROOT/dist/hanlin-ipad-build"
OUTPUT_DIR="$ROOT/dist/hanlin-ipad-ipa"
PROJECT="$PROJECT_DIR/LorvexAppleNative.xcodeproj"

for tool in xcodegen xcodebuild xcrun python3 unzip zip ditto; do
  command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 2; }
done

# Preserve Lorvex's release schema gate.
python3 "$ROOT/script/verify_schema_freeze.py" --release
bash "$ROOT/script/verify_schema_embed.sh"

mkdir -p "$PROJECT_DIR" "$BUILD_DIR" "$OUTPUT_DIR"
xcodegen --spec "$ROOT/Config/XcodeGen/project.yml" \
  --project "$PROJECT_DIR" --project-root "$ROOT" --quiet

# An added Hanlin SDK changes SwiftPM's dependency graph. Resolve dependencies
# in the disposable generated project rather than enforcing Lorvex's pre-Hanlin
# lock (which does not yet contain swift-ai-sdk and its transitive packages).
set -o pipefail
xcodebuild -project "$PROJECT" -scheme LorvexMobileApp \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath "$BUILD_DIR" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO \
  build 2>&1 | tee "$OUTPUT_DIR/lorvex-hanlin-build.log"

APP="$BUILD_DIR/Build/Products/Release-iphoneos/LorvexMobileApp.app"
[[ -d "$APP" ]] || { echo "Compiled application missing: $APP" >&2; exit 1; }
# The app must embed every dynamic SwiftPM framework used by its libraries.
python3 "$ROOT/script/verify_macho_closure.py" "$APP"
PLIST="$APP/Info.plist"
[[ -f "$PLIST" ]] || { echo "App has no Info.plist" >&2; exit 1; }
EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$PLIST")"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$PLIST")"
BUILD_NO="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$PLIST")"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST")"
ARCHS="$(xcrun lipo -archs "$APP/$EXECUTABLE")"
[[ " $ARCHS " == *" arm64 "* ]] || { echo "IPA binary is not arm64" >&2; exit 1; }

STAGING="$OUTPUT_DIR/.unsigned-ipa-staging"
rm -rf "$STAGING"
mkdir -p "$STAGING/Payload"
ditto "$APP" "$STAGING/Payload/LorvexMobileApp.app"
IPA="$OUTPUT_DIR/Lorvex-Hanlin-iPad-$VERSION+$BUILD_NO-UNSIGNED.ipa"
rm -f "$IPA"
(cd "$STAGING" && zip -qry "$IPA" Payload)
unzip -tq "$IPA" > "$OUTPUT_DIR/ipa-zip-validation.txt"
unzip -Z1 "$IPA" | grep -q '^Payload/LorvexMobileApp.app/Info.plist$'
rm -rf "$STAGING"

export IPA BUNDLE_ID BUILD_NO VERSION ARCHS
python3 - <<'PY'
import hashlib,json,os,pathlib
p=pathlib.Path(os.environ["IPA"])
receipt={
 "kind":"lorvex-hanlin-ipad-unsigned-ipa-v1",
 "artifact":p.name,
 "bytes":p.stat().st_size,
 "sha256":hashlib.sha256(p.read_bytes()).hexdigest(),
 "bundleID":os.environ["BUNDLE_ID"],
 "version":os.environ["VERSION"],
 "build":os.environ["BUILD_NO"],
 "architectures":os.environ["ARCHS"].split(),
 "signed":False,
 "installable":False,
 "nextStep":"Sign with an authorized Apple Developer identity and device provisioning before installing or uploading to TestFlight."
}
(p.parent/"Lorvex-Hanlin-iPad-manifest.json").write_text(
 json.dumps(receipt,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
print(json.dumps(receipt,indent=2))
PY
echo "Unsigned IPA exported to $IPA"
