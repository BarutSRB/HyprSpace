---
title: Installation
description: Install OmniWM with Homebrew, Nix, or a GitHub release, grant the required permissions, and keep it updated.
sidebar:
  order: 2
---

## Requirements

- macOS 26+ (Tahoe) on Apple Silicon
- Accessibility and Input Monitoring permissions (required at launch)
- Screen Recording permission for Overview thumbnails, drag previews, and captured Hidden Bar glyphs (optional)
- `Displays have separate Spaces` **ON** (the macOS default; OmniWM pauses window management until it is enabled)

## Homebrew

```bash
brew tap BarutSRB/tap
brew install omniwm
```

Then finish with the [first-launch setup](#first-launch-setup) below.

## Nix

OmniWM supports both community-maintained Nix packages below, alongside a real-world Home Manager configuration example. The packages install official OmniWM release artifacts, while their Nix expressions are maintained by DoomHammer and DavSanchez respectively.

| Package or example | Best for | Packaging or configuration difference |
| --- | --- | --- |
| [DoomHammer NUR package](https://nur.nix-community.org/repos/doomhammer/) | Fast release tracking | Its current `unzip` extraction does not preserve the release's valid Developer ID signature, and it installs the app bundle without exposing `omniwmctl` on `PATH`. |
| [DavSanchez package](https://github.com/DavSanchez/nix-dotfiles/blob/master/pkgs/omniwm.nix) and [Home Manager module](https://github.com/DavSanchez/nix-dotfiles/blob/master/modules/home/omniwm.nix) | Signature-preserving, declarative integration | It may trail the latest release, but its `bsdtar` extraction preserves code signing and it provides `omniwmctl`, Home Manager settings, and launchd integration. |
| [ryoppippi Home Manager configuration](https://github.com/ryoppippi/dotfiles/tree/main/nix/modules/darwin/programs/omniwm) | Real-world declarative setup example | It builds on DavSanchez's module, enables launchd, and merges a tracked settings template while preserving GUI-managed, machine-specific monitor settings. |

Install the fast-tracking DoomHammer package directly:

```bash
nix profile install github:DoomHammer/nur-packages#omniwm
```

Existing NUR configurations can use `nur.repos.doomhammer.omniwm`.

Install the signature-preserving DavSanchez package directly:

```bash
nix profile install github:DavSanchez/nix-dotfiles#omniwm
```

For a declarative setup, use DavSanchez's exported [`homeModules.omniwm`](https://github.com/DavSanchez/nix-dotfiles/blob/master/modules/home/omniwm.nix) and `overlays.additions`. After either installation, finish with the [first-launch setup](#first-launch-setup) below.

## GitHub Releases

1. Download the latest `OmniWM-v<version>.zip` app archive from [Releases](https://github.com/BarutSRB/OmniWM/releases).
2. Extract and move `OmniWM.app` to `/Applications`.
3. Continue with the first-launch setup.

## First-launch setup

1. In **System Settings > Desktop & Dock > Mission Control**, turn **ON** `Displays have separate Spaces`.
2. Log out of macOS and log back in for that change to take effect, unless you had it on already.
3. Launch OmniWM and grant **Accessibility** and **Input Monitoring** when prompted. Both are required at launch.
4. Optionally grant **Screen Recording** for capture-derived visuals: Overview thumbnails, drag previews, and captured Hidden Bar glyphs.

:::note
An optional **System Hyper Trigger** (acting as the `Hyper` chord while a key or mouse button is held) also needs the Input Monitoring permission. See [Keyboard Shortcuts](/guides/keyboard-shortcuts/).
:::

## Updates

OmniWM checks for updates by default:

- On launch, OmniWM polls the latest GitHub release at most once per day.
- Updates stay manual. OmniWM does not auto-download or auto-install a new release.
- When a newer release is available, OmniWM shows a centered popup with release notes and actions for `Open Release Page`, `Copy brew upgrade omniwm`, `Skip This Version`, and `Not Now`.
- You can control this from **Settings > General > Updates** or trigger a manual check from the status bar menu with `Check for Updates...`.
