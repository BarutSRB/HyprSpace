---
title: Building from Source
description: Toolchain requirements, the GhosttyKit preflight, and the commands to build, run, test, and verify OmniWM.
sidebar:
  order: 2
---

OmniWM builds with Swift Package Manager on macOS 26.0+ (Apple Silicon) and needs Swift 6.4 or newer.

## Requirements

- SwiftPM with Swift 6.4+
- macOS 26.0+
- A complete GhosttyKit xcframework at `Frameworks/GhosttyKit.xcframework` (see below)

## GhosttyKit Preflight

The Quake Terminal links against a complete local GhosttyKit xcframework that is not in git. Download the latest `GhosttyKit.xcframework-v<version>.zip` asset from [Releases](https://github.com/BarutSRB/OmniWM/releases), then extract it into `Frameworks/` so the final path is `Frameworks/GhosttyKit.xcframework` — or replace the complete bundle with one you build from Ghostty.

As part of `make build`, `Scripts/ghostty-preflight.sh` verifies that the internal arm64 archive at the path pinned in `Scripts/build-metadata.env` (currently `Frameworks/GhosttyKit.xcframework/macos-arm64/libghostty-internal.a`) is arm64-only and matches the pinned SHA-256. If you rebuild GhosttyKit, replace the complete xcframework and update the metadata pin.

## Build, Run, Test, Verify

```bash
make build     # Ghostty preflight + arm64 debug build
make run       # Package, development-sign, and launch dist/OmniWM.app
swift test     # Default test suite (environment-dependent live tests are opt-in)
make verify    # format-check + lint + build — run this before opening a pull request
```

Use `make run` for day-to-day development. It builds, packages, development-signs, and opens `dist/OmniWM.app` through LaunchServices — the canonical development launch because it gives OmniWM its normal app identity. Note that OmniWM uses its native status bar item only while Hidden Bar concealment is inactive; while concealment is active it shows a separate fallback icon beside a visible workspace bar, or near the display's top center when no workspace bar is visible. That behavior applies to both bundled and raw `swift run OmniWM` launches and is not specific to Debug builds.

## Formatting and Linting

`make format` and `make lint` pin exact tool versions (SwiftFormat 0.63.0, SwiftLint 0.65.1) and fail on any other version, so install those exact versions. SwiftFormat's `fileHeader` rule also enforces the two-line SPDX/GPL-2.0 header that every Swift source and test file under `Sources/` and `Tests/` must start with — never strip or reword it. (`Package.swift` is the exception; its `swift-tools-version` directive stays on line one.)
