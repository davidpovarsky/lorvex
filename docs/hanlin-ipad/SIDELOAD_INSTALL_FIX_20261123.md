# Lorvex Hanlin iPad — IXErrorDomain 8 installation compatibility

## Evidence
- Green iPad native build and unsigned IPA: https://github.com/davidpovarsky/lorvex/actions/runs/45076375705
- Xcode 27 SDK tests: success. Debug ARM64 iOS build: success. IPA ZIP: success.
- An iPad installation attempt rejected the nested app-extension placeholder:

  Parent expected: com.lorvex.apple.NA6HPWARQ2.*
  Nested Focus Filter actually: com.lorvex.apple.focus-filter
  IXErrorDomain Code=8 / Mismatched bundle IDs.

The Xcode project declares the original parent as com.lorvex.apple and child
as com.lorvex.apple.focus-filter, which is correct *until* a sideload
signing/installation service rewrites the parent identifier to
com.lorvex.apple.NA6HPWARQ2. At that point, the service must also rename
and sign every nested extension to match the modified parent. This
particular installation path did not do so.

Build success never guaranteed iPadOS installability. The green IPA
is explicitly unsigned, so it must be signed before device installation.

## Two distribution tracks

1. FULL WITH ALL FEATURES — keep the original IPA. Sign the main app AND
   all embedded extension/watch bundles with proper matching identifiers.
   A signer changing the main app ID must also rewrite and re-sign each
   extension. Do not send unsigned IPA to TestFlight as if installable.

2. SIDELOAD-COMPATIBLE WITHOUT EXTENSIONS — for signing services that
   rewrite ONLY the main app bundle ID, use the new SIDELOAD IPA.
   Repackage from the exact green IPA, preserve compiled application,
   Hanlin engine, frameworks, zip metadata and binary bytes. Remove
   PlugIns/, Watch/, Extensions/ and SystemExtensions/ under the app.
   This avoids the specific nested-extension placeholder mismatch after
   the service adds a suffix to the main bundle ID. Focus Filter, widgets
   and Watch companion functionality are absent in this variant.
   It is STILL UNSIGNED and needs proper signing/provisioning.

## Automation and evidence

- apps/apple/script/package_sideload_compat_ipa.py: repackages a validated
  existing IPA without recompiling Swift. Writes manifest with input and
  output SHA256, bundle ID, removed entries and signing limitations.
- apps/apple/script/test_package_sideload_compat_ipa.py: tests executable
  and framework preservation, symlink mode preservation, extension
  removal, source immutability and error on attempting re-stripping.
- .github/workflows/lorvex-sideload-compat.yml: downloads exactly the
  previously proven native IPA in run 45076375705 and publishes a
  sideload-compatible variant, not a full product replacement.
- The heavy native workflow is path-filtered so a packaging-only fix
  does not rerun all Swift/Xcode native compilation.

## Acceptance boundary

A valid ZIP and correctly scoped bundle IDs do not establish physical
installation on the user's iPad. Live installation with the user's
signing service is the final gate; do not mark passed before evidence.
