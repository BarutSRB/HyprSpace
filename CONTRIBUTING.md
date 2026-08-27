# Contributing

Thanks for wanting to help with OmniWM.

Bug fixes, documentation improvements, performance work, focused cleanups, features, and thoughtful ideas are all welcome.

## What Makes a Good Contribution

- Fix bugs or regressions
- Improve documentation or onboarding
- Add useful features or workflow improvements
- Improve performance or reduce latency
- Clean up code when it clearly improves maintainability
- Share demos, examples, or tutorials

## Project Direction

- Refactors are fine when they solve a real problem, but they should come with a detailed reason. Explain what is not working well today, why the refactor is needed, and what it improves.
- Please keep contributions in Swift so the codebase stays cohesive.

## Before Opening a Pull Request

- For larger changes, open an issue or start a discussion first so we can align on direction.
- Keep changes focused. Smaller, well-explained pull requests are much easier to review and merge.
- If your change affects behavior, config, docs, or CLI output, call that out clearly in the pull request description.

## Pull Request Expectations

- Explain the problem you are solving and why this approach makes sense.
- Include verification notes **if possible**. Mention what you ran, checked, or verified.
- Add screenshots, recordings, or CLI examples when they help explain the change.
- Update documentation when behavior, workflows, or interfaces change.

## Building and Verifying

OmniWM builds with Swift Package Manager on macOS 26+ (Apple Silicon) and needs Swift 6.4 or newer. The Quake
Terminal links against a complete local GhosttyKit xcframework that is not in git. Download the latest
`GhosttyKit.xcframework-v<version>.zip` asset from [Releases](https://github.com/BarutSRB/OmniWM/releases), then extract
it into `Frameworks/` so the final path is `Frameworks/GhosttyKit.xcframework`. `Scripts/ghostty-preflight.sh` verifies
the internal arm64 archive at the path pinned in `Scripts/build-metadata.env` (currently
`Frameworks/GhosttyKit.xcframework/macos-arm64/libghostty-internal.a`) is arm64-only and matches the pinned SHA-256.
If you rebuild GhosttyKit, replace the complete xcframework and update the metadata pin.

```bash
make build     # Ghostty preflight + arm64 debug build
make run       # Package, development-sign, and launch dist/OmniWM.app
swift test     # Default test suite (environment-dependent live tests are opt-in)
make verify    # format-check + lint + build — run this before opening a pull request
```

`make format` and `make lint` pin exact tool versions (SwiftFormat 0.62.1, SwiftLint 0.65.1) and fail on any other
version, so install those exact versions. SwiftFormat's `fileHeader` rule also enforces the two-line SPDX/GPL-2.0
header that every Swift source and test file under `Sources/` and `Tests/` must start with — never strip or reword
it. (`Package.swift` is the exception; its `swift-tools-version` directive stays on line one.)

## Trace Files

Include a trace file when possible, especially with bug reports. It records OmniWM activity and state around the problem. Open **Settings → Troubleshooting**, click **Start Recording**, reproduce the bug, then click **Stop & Save Recording** and attach the saved `.log` file.

**Report a Bug…** in the status-bar menu opens the in-app report form instead. Recording or selecting trace and crash evidence there is optional; on submit OmniWM prepares one fresh diagnostic `.log` with whatever you selected, reveals it for attaching, and opens a pre-filled GitHub issue.

Before attaching a diagnostic, review the `.log`: it can contain OmniWM settings, application and window titles, and title-based App Rule matchers.

Captures can also be scripted once IPC is enabled: `omniwmctl capture start trace`, `omniwmctl capture stop`, and `omniwmctl capture status`.

## Basic Workflow

1. Fork the repository.
2. Create a branch for your change.
3. Make the change and verify it.
4. Open a pull request with clear context and reasoning.

## Improving the AI Issue-Report Prompt

The prompt that rewrites bug reports into GitHub issues lives in plain Markdown, so you can improve it without editing Swift. See [docs/issue-report-prompt.md](docs/issue-report-prompt.md) for the files to edit, the constraints to preserve, and how to test.

## Questions and Ideas

If you are unsure about something, open an issue or ask in the pull request. Thoughtful questions are always welcome.

Thanks again for helping improve OmniWM.
