# Original Hanlin Composer live draft — Lorvex native repair

## Actual UI result and visual evidence

[Run 45133684085](https://github.com/davidpovarsky/lorvex/actions/runs/45133684085) built and launched the actual Lorvex iPad app on Xcode 27.2 (27B52) / iOS 27.2. The original native editor, multiline input, enabled Send control, Morph panel and real host tool catalog were exercised. The unchanged original test failed its draft-content assertion at line 37; closing/reopening the assistant was not reached.

The original screenshot taken **before opening Morph** already shows the initial P at the end: `lan this week` followed by `Keep time for reading and rest.P`. The later panel screenshot retains the same text. This establishes a typing/caret ordering defect, not a panel-close data-loss cause. The exact delegate/render interleaving was not traced on this run.

The retained GitHub artifact is **14803208882**, 98,005,168 bytes, SHA-256 `9e2579a945d86b0d9964d3a8583eef1c43ee3012747b083f6a68a1020a028eb8`. Its native multiline PNG is `53B1B018-1092-4C98-8CF2-8C4E4ED729B6.png`, SHA-256 `3830df391bb72bf07263532ad26d0e33bd2fc386719f7a4ba2267bbece973ab0`. Three original XCTest screenshots and the recorded video were retained and visually inspected. No successful UI result is claimed here.

## Corrected owner contract

Code commit `ddabf543781e6f6425dd604fd586bfce09c5a223` pins canonical SDK **0dae98f7b44b3cb4ee4d8dacd1913f2ed317a965**. It retains the original public `HanlinComposerDraft` reference in the assistant view and passes that exact reference through workspace/composer. The native editor Binding writes and `readCurrentTextState` reader now address the same live owner. Send reads and clears it directly.

Previously, text and revision lived in separate SwiftUI State values and the editor's supposed live-state callback read captured Binding values. That did not satisfy the canonical synchronous-owner contract and did not preserve the original atomic snapshot update. Original Hanlin's draft class now lives in HanlinChatUI; the original app consumes the same implementation through its compatibility name. Stable owner identity, a new revision for every write (including same-value clears), and exact text bytes are preserved. There is no consumer copy of the implementation and no UIKit dependency in LorvexHanlinAgent. Existing non-UIKit presentation fallbacks remain guarded.

The editor, keyboard handling, text geometry, Morph animation, 22 host tools, agent/session stores and original XCTest selector/assertions are unchanged.

## Exact verification and continuation boundary

The canonical consumer bootstrap fetched the installer from the new locked revision. Sparse installation and canonical `--check` passed on Oracle. The generated Package.swift is byte-identical to the prior selected profile (SHA-256 `29c126b9305e88bbcaed57512374e986f7225a0c87d332950f6ba3deda9bca26`). All **534 existing selected source/resource entries** have identical paths, modes and Git objects. The only added selected file is the original live draft class, Git blob `23002e64c4491cd3278f4cb5e7ab630cdd4492f3`; no native binary targets are selected.

The complete 1696-entry host Sources inventory is checked against the accepted baseline after normalizing only the three reviewed draft adapter files. Package manifests, dependency lock, all original tests, core implementation, configuration and Agent module are unchanged. The separate machine-readable receipt contains every one of the 535 current selected SDK entries. Both actual workflow source guards passed locally; all other workflow steps/fields, the default full scope, timeouts and original UI assertions are unchanged.

The original `HANLIN_NATIVE_ACCEPTANCE_20261123.json` is preserved without rewriting its historical claims. Its six native Agent tests remain bound to run **45119218473**, consumer **09307ef346eb12be2bcb25141d4b76bc9beb6ed6**, SDK **d49a4fd4115b8335105d2991bf74ab4d7f6aad2d**. That run's actual device build/export remains evidence for its original binary only. It is not relabeled as a newly built repaired device binary.

Only the failed original UI scope will run against the published repaired source. The code/receipt commits use `[skip ci]` to avoid unrelated automatic repeats; the explicit original native UI workflow remains required. This document records the correction and source checks, with native acceptance still pending.
