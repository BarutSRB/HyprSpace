# Window classification fixtures

Each `*.json` file is a `WindowClassificationRegressionFixture`.
`WindowClassificationRegressionTests` feeds each observation and its referenced rules snapshot through
`WindowClassificationReproducer.recompute` and asserts the result matches the independently authored
`expectedDecision`. The captured `observedDecision` is evidence only and never defines correct behavior.

The disposition is the ownership boundary. `managed` and `floating` are semantic windows OmniWM owns;
`unmanaged` surfaces stay outside authoritative window state. Popup, accessory, parented, non-window-role,
and system-overlay fixtures must not be represented as managed windows with capabilities suppressed later.

## Adding a fixture

1. Find the relevant `WindowClassificationObservation` in the submitted runtime trace.
2. Add it as the fixture's `observation`, copy its referenced rules snapshot into `rules`, and use a
   descriptive filename (`<app>-<case>.json`).
3. Independently determine the correct ownership and author `expectedDecision`; do not copy it from
   `observedDecision` without reviewing the reported problem. Positive root-window fixtures must include
   matching WindowServer identity and root-parent evidence; buttonless dialog and floating-window fixtures
   must also preserve tri-state `isMain` and `isModal` AX facts.
4. Run `swift test --filter WindowClassificationRegressionTests`.
