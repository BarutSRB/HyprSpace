# Window classification fixtures

Each `*.json` file is a `WindowClassificationRegressionFixture`.
`WindowClassificationRegressionTests` feeds each observation and its referenced rules snapshot through
`WindowClassificationReproducer.recomputeOutcome` and asserts the result matches the independently
authored `expectedDecision` **and** `expectedPolicy`. The captured `observedDecision` is evidence only
and never defines correct behavior.

## `expectedPolicy`

`expectedPolicy` is the `WindowInteractionPolicy` the decision resolves to — `full`,
`handsOffSurface`, or `untracked` (a non-preset combination serialises as
`custom(mayFocus,mayBorder,…)`).

It is required, and it is not redundant with `expectedDecision`. A disposition says *where the window
goes*; the policy says *what OmniWM is allowed to do to it*. #536 was a case where the disposition was
right (`floating`) and the capability set was wrong, so a corpus asserting disposition alone could not
see the bug — `02-accessory-without-close-floating.json` encodes that exact input and passed throughout.

## Adding a fixture

1. Find the relevant `WindowClassificationObservation` in the submitted runtime trace.
2. Add it as the fixture's `observation`, copy its referenced rules snapshot into `rules`, and use a
   descriptive filename (`<app>-<case>.json`).
3. Independently determine the correct behavior and author `expectedDecision` and `expectedPolicy`; do
   not copy them from `observedDecision` without reviewing the reported problem.
4. Run `swift test --filter WindowClassificationRegressionTests`.
