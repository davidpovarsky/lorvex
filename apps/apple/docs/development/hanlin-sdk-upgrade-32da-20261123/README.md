# Canonical Hanlin SDK upgrade to 32da9e31

The actual Lorvex consumer now locks **32da9e314e22bbf22391fcf8902302acfbb281e2**. Code commit **0ad4c5b1c5b28f9d8abf82481bbf2e2431cfbb07** changes only HanlinSDK.lock.json. All seven public product selections and the original host source, tests, configuration, native scripts and package resolution remain unchanged.

## Actual canonical installation

The existing host bootstrap fetched Scripts/SDK/install.py from that exact new revision and used the shared canonical Git cache. Installation passed in3.028s; canonical check passed in0.265s. No native artifact, Apple build, test, live model call or CI run was performed.

All **535** actual selected file contents, executable/symlink modes and directory membership were matched to the immutable32da Git objects. The generated Package.swift remains byte-identical to the accepted profile. Both binaryTargets and managedNativeTargets are empty. The exact installed receipt is [canonical-installation.json](canonical-installation.json), with commands, timings, selected deltas, source hashes and host input identities in [receipt.json](receipt.json).

The **only selected implementation change** from the accepted0dae profile is the original provider endpoint-query duplicate-key crash fix. Every selected Composer, native editor, original draft owner, bubble, renderer, resource and UI source is unchanged. Lorvex does not select ScriptUI, the legacy grant store or AtomicScriptStore. Their newer fixes do not change this host profile.

## Preserve actual native evidence

The [original UI run45148401438](https://github.com/davidpovarsky/lorvex/actions/runs/45148401438) remains one passed case and four reviewed frames at **2e6a5e20 / SDK0dae**. Its accepted multiline/Morph behavior is not relabeled as a new32da execution. The older six Agent cases and device export retain **09307ef3 / SDKd49 / run45119218473**; the five presentation cases retain their own run45109608536 provenance.

The historical draft-repair, UI-acceptance and native-acceptance JSON files and workflow are byte-identical to their earlier committed inputs. The old UI-only continuation intentionally still requires its exact0dae repair profile. This update does not rewrite that record, loosen its guard or dispatch it against different source. A future changed-scope run needs its own exact source admission; this lock/install/check upgrade requires no UI replay.

The shared [final source qualification](https://github.com/davidpovarsky/hanlin-ai/blob/b6a278531b5bfbc7246b4f5fec7d676750c645a5/Docs/SDK/HanlinConsumerUpgradeQualification20261123.md) binds the source delta and reuses the exact existing provider-fix controls. A common candidate Apple compile remains separately attributed; no new host binary, live-provider, physical-device or signed-distribution acceptance follows from this receipt. Skip-ci preserves that narrow scope.
