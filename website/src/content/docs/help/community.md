---
title: Community & Support
description: Community integrations, related forks, support links, and how to report bugs or contribute.
sidebar:
  order: 2
---

## Community integrations

- **[OmniWM Computer Use](https://github.com/nick-s5/omniwm-computer-use)** is a community-maintained Codex skill for focus-safe Computer Use, browser automation, and app testing through `omniwmctl` across OmniWM workspaces and displays.
- **[OmniCast](https://github.com/imprisonedmind/omni-cast)** is a community-maintained Raycast extension for controlling OmniWM with plain-English search and commands through `omniwmctl`.

Both build on OmniWM's bundled CLI — see the [CLI overview](/reference/cli/overview/).

## Related forks

- **[Nehir](https://github.com/apphane-dev/nehir)** is an endorsed OmniWM fork focused on a narrower, more opinionated Niri-style scrolling-column workflow. It may be friendlier for beginners who want guided defaults and a smaller feature surface, while OmniWM remains the broader upstream project with multiple layout modes and the full feature set.
- **[choru-k/OmniWM](https://github.com/choru-k/OmniWM)** is an interesting personal OmniWM fork experimenting with opt-in workflow layers on top of upstream OmniWM, including zone anchors for the Niri strip, a configurable F13-F20 leader-key chord menu, tabbed-column keyboard cycling, and trackpad-friendly modifier resizing. It is best read as a power-user workflow branch rather than a replacement for the main OmniWM release.

## Support development

If you find OmniWM useful, consider supporting development:

- [GitHub Sponsors](https://github.com/sponsors/BarutSRB)
- [PayPal](https://paypal.me/beacon2024)

## Reporting bugs

The best way to report a bug is from inside OmniWM: open the status-bar menu and choose **Report a Bug…**. That opens the in-app report form, where recording or attaching trace and crash evidence is optional. On submit, OmniWM prepares one fresh diagnostic `.log` (with any evidence you selected appended), reveals it in Finder for you to attach, and opens a pre-filled GitHub issue — OmniWM never sees your GitHub login.

:::caution[Review before you attach]
Review the `.log` before attaching it to a public issue: it can include settings, app and window titles, and title-based rule matchers.
:::

Prefer the web? The [GitHub issue form](https://github.com/BarutSRB/OmniWM/issues/new/choose) works too; please include your OmniWM and macOS versions there.

## Contributing

Issues and pull requests are welcome on [GitHub](https://github.com/BarutSRB/OmniWM). Start with [CONTRIBUTING.md](https://github.com/BarutSRB/OmniWM/blob/main/CONTRIBUTING.md) for the project guidelines, expectations, and preferred direction.
