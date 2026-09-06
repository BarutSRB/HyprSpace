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

OmniWM is packaged in [nixpkgs](https://github.com/NixOS/nixpkgs/blob/master/pkgs/by-name/om/omniwm/package.nix), maintained by mmfallacy and samiser, and Home Manager ships an official [`programs.omniwm` module](https://github.com/nix-community/home-manager/blob/master/modules/programs/omniwm.nix), maintained by DavSanchez. The package installs the signed release artifact with `bsdtar`, so the Developer ID signature stays valid, and exposes `OmniWM` and `omniwmctl` on `PATH`. Both currently live on unstable branches only (the nixpkgs unstable channels and Home Manager `master`) and may trail the latest GitHub release.

Install the package directly:

```bash
nix profile install nixpkgs#omniwm
```

With nix-darwin or Home Manager, add `pkgs.omniwm` to `environment.systemPackages` or `home.packages`.

For a declarative setup, enable the Home Manager module. It installs the package, runs OmniWM as a launchd agent, and writes `~/.config/omniwm/settings.toml` from an attribute set or a tracked TOML file:

```nix
programs.omniwm = {
  enable = true;
  settings = ./omniwm-settings.toml;
};
```

After either installation, finish with the [first-launch setup](#first-launch-setup) below.

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
