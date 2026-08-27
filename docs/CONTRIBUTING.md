---
title: OmniWM Contribution Guide
---

# OmniWM Contribution Guide

This page is the contributor entry point for the docs site. The canonical contribution guide lives in the repository root at [CONTRIBUTING.md](https://github.com/BarutSRB/OmniWM/blob/main/CONTRIBUTING.md).

This page stays short on purpose so the actual project rules only have one source of truth.

## Start Here

- Read the [canonical contribution guide](https://github.com/BarutSRB/OmniWM/blob/main/CONTRIBUTING.md).
- Review the [Architecture Guide](ARCHITECTURE.md) if your change touches core internals, layout behavior, or app structure.
- Review the [IPC & CLI Reference](IPC-CLI.md) if your change affects automation, commands, queries, or scripting.
- For the user-facing overview, installation notes, and screenshots, see the [README](https://github.com/BarutSRB/OmniWM/blob/main/README.md).
- Before opening a pull request, run the checks the canonical guide asks for — `make verify` (format-check + lint + build), plus `swift test` where it applies. That guide also covers the pinned SwiftFormat/SwiftLint versions and the GhosttyKit prerequisite.

## Project Direction at a Glance

- Refactors are welcome when they come with a detailed reason and a clear benefit.
- Keep contributions in Swift.
