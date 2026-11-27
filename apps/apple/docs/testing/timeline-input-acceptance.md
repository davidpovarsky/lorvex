# Timeline native pinch acceptance

The original native iPhone Hebrew run on source 5095da18 requested an XCTest
pinch scale of 1.25 at velocity 0.6. Its retained synthesized event contains
two original touch paths. Their separation changed from 6.619446 to
17.601364 points, a delivered factor of 2.659039. The rendered Timeline
changed from 150% to 392%, a factor of 2.613333 (1.72% below delivered input).
The old fixed upper ratio of 1.6 therefore rejected correct behavior.

Apple documents the synthesized pinch as best effort, without absolute
accuracy guarantees:
https://developer.apple.com/documentation/xcuiautomation/xcuielement/pinch(withscale:velocity:)

The replacement acceptance keeps the real gesture, its requested parameters,
the before/after accessibility readings, and all rendered date-range, bounds,
canonical task, cancellation, and relaunch checks. It adds a retained numeric
observation. It does not alter the application or TaskVisualizationKit.

A successful XCTest result alone is insufficient. For each iPhone/iPad and
English/Hebrew interaction result:

1. Set SystemAttachmentLifetime to keepAlways in the dispatched .xctestrun,
   so original system events survive a passing test.
2. Run the complete original interaction case.
3. Run verify_timeline_pinch_input.py --xcresult RESULT --output NEW_DIRECTORY.
4. Bind its passing receipt, original event, observation, activity tree and
   test-result hashes into the final native acceptance.

The independent verifier requires exactly one passing original case and one
original Timeline pinch, two complete synchronized touch paths, a retained
observation immediately after that event, and observed zoom within 10% of
the delivered distance ratio. It rejects missing events, a nominal-request
substitution, compounded magnification, no magnification, nonfinite input,
and clamping that would conceal incorrect proportional zoom. Its tolerance
accounts for the native recognizer's activation threshold and rounded
percentage accessibility values; it is applied to measured input, not to
an invented nominal factor.

Original failed results remain historical failures. They are diagnostic
evidence for this correction, never substituted for the four passing final
native cases and independent input comparisons.
