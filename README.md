# HyprSpace a Heavily Enhanced Fork of AeroSpace

**HYPRLAND**
<p align="center">
  <img src="https://github.com/BarutSRB/HyprSpace/raw/289dfc3487dab445f60a846b1a86e2d98fd34d3b/CleanShot%202025-10-20%20at%2015.18.44%402x.png" width="100%">
</p>

**NIRI**
<p align="center">
  <img src="https://github.com/BarutSRB/HyprSpace/blob/a28fd688c620df39c69219043f29413e459ac0b8/CleanShot%202025-10-21%20at%2014.15.01.gif" width="100%">
</p>

**AeroSpace** is an i3-like tiling window manager for macOS

*This fork adds three exclusive features: **Centered Workspace Bar** + **Dwindle Layout** + **Niri Layout***

[Download Latest Release](../../releases) • [Original AeroSpace](https://github.com/nikitabobko/AeroSpace) • [Report Issues](../../issues)

---

## ✨ What's New in This Fork

This fork enhances the original AeroSpace with **three powerful features** not available upstream:

### 🎯 Centered Workspace Bar
A macOS integrated menu bar that displays workspace indicators and full GUI window icons **centered at the top of your screen**.

**Features:**
- 📍 Centered workspace indicators (not in system tray)
- 🪟 Window icons for each workspace
- 🖱️ Interactive: Click to focus workspace or window
- 🎨 Multi-monitor support with configurable target display
- 🔧 Highly customizable via menu:
  - Window level (Status/Popup/Screensaver)
  - Target display (Focused workspace/Primary/Mouse cursor)
  - Notch-aware positioning for MacBook Pro
  - Deduplicate app icons with badge count
  - Toggle workspace numbers

### 🌀 Dwindle Layout
A binary tree-based tiling layout inspired by Hyprland's dwindle algorithm.

**Features:**
- 📐 Automatic split direction based on available space
  - Wider areas split vertically (left/right)
  - Taller areas split horizontally (top/bottom)
- ⚖️ Weight-aware splitting for precise window sizing
- 🔄 Alternating orientation creates characteristic dwindle pattern
- 🛠️ Full support for `resize`, `balance-sizes`, and `horizontal`/`vertical` commands
- 🎯 Perfect for dynamic, organic workspace layouts

**Inspired by:** [Hyprland](https://github.com/hyprwm/Hyprland)

### 🎠 Niri Layout
A carousel-style layout where the focused window is centered with neighboring windows peeking at the edges.

**Features:**
- 🎯 Focused window centered at 80% screen width
- 👀 Peek effect: 10% margins show neighboring windows on left/right
- 📏 Custom widths: Resize any window, custom sizes preserved
- ➡️ Horizontal-first: Optimized for wide monitors
- 🔄 Smooth focus-based carousel navigation
- 🎨 Works great with minimal gaps for clean aesthetics

**Config usage:** Use `layout scroll` in your .toml file

**Perfect for:** Single-row workflows, presentation mode, MacBook displays

**Inspired by:** [Niri Compositor](https://github.com/YaLTeR/niri)

---

## Installation

### 📦 Download & Install

Choose your preferred installation method from the [latest release](../../releases/latest):

#### Option 1: DMG Installer (Recommended)

1. **Download** `HyprSpace-v*.dmg`
2. **Open** the .dmg file
3. **Drag** HyprSpace.app to the Applications folder
4. **First Launch Only** - Bypass Gatekeeper:
   - **Right-click** HyprSpace.app → Select **"Open"**
   - Click **"Open"** in the security dialog
   - *Alternative:* Run in Terminal:
     ```bash
     xattr -cr /Applications/HyprSpace.app
     ```
5. **Grant Accessibility Permissions** when prompted

#### Option 2: ZIP Archive (Includes CLI & Extras)

1. **Download** `HyprSpace-v*.zip`
2. **Extract** the archive
3. **Move** `HyprSpace.app` to your Applications folder
4. **Optional - Install CLI:**
   ```bash
   # Copy CLI binary to a directory in your PATH
   cp HyprSpace-v*/bin/hyprspace /usr/local/bin/

   # Copy man pages (optional)
   cp HyprSpace-v*/manpage/*.1 /usr/local/share/man/man1/

   # Copy shell completion (optional - choose your shell)
   cp HyprSpace-v*/shell-completion/bash/_hyprspace /usr/local/etc/bash_completion.d/
   # OR for zsh:
   cp HyprSpace-v*/shell-completion/zsh/_hyprspace /usr/local/share/zsh/site-functions/
   # OR for fish:
   cp HyprSpace-v*/shell-completion/fish/hyprspace.fish ~/.config/fish/completions/
   ```
5. **Bypass Gatekeeper** (same as Option 1, step 4)
6. **Grant Accessibility Permissions** when prompted

### 🔧 Enable Features

#### Centered Workspace Bar
1. Click the HyprSpace **menu bar icon**
2. Navigate to **"Experimental UI Settings"**
3. Click **"Enable centered workspace bar"**
4. Customize settings in the same menu

#### Dwindle Layout

Add to your `~/.hyprspace.toml`:

```toml
# Set as default layout
default-root-container-layout = 'dwindle'

# Or add a keybinding to toggle
[mode.main.binding]
cmd-shift-d = 'layout dwindle'
```

---

## Configuration

### Centered Bar Settings

All settings accessible via **Menu Bar Icon → Experimental UI Settings**:

- ✅ Enable centered workspace bar
- 🔢 Show workspace numbers
- 📊 Window Level:
  - Status Bar
  - **Popup (above menu bar)** ← Recommended
  - Screen Saver (highest)
- 🖥️ Target Display:
  - **Focused Workspace Monitor** ← Recommended
  - Primary Display
  - Display Under Mouse
- 💻 Notch-aware positioning (MacBook Pro)
- 🎯 Deduplicate app icons with badge count

### Dwindle Layout Example

```toml
# ~/.hyprspace.toml

# Set dwindle as default
default-root-container-layout = 'dwindle'

[mode.main.binding]
# Toggle layouts
cmd-shift-t = 'layout tiles'
cmd-shift-a = 'layout accordion'
cmd-shift-d = 'layout dwindle'

# Resize works with dwindle
cmd-shift-h = 'resize width -50'
cmd-shift-l = 'resize width +50'
cmd-shift-equal = 'balance-sizes'

# Change orientation
cmd-shift-o = 'layout horizontal'
cmd-shift-v = 'layout vertical'
```

**Dwindle Layout Progression:**
```
1 window:           2 windows (h):      3 windows:          4 windows:
┌─────────┐        ┌────┬────┐         ┌────┬────┐         ┌────┬────┐
│         │        │    │    │         │    │ 2  │         │    │ 2  │
│    1    │   →    │ 1  │ 2  │    →    │ 1  ├────┤    →    │ 1  ├────┤
│         │        │    │    │         │    │ 3  │         │    │ 3,4│
└─────────┘        └────┴────┘         └────┴────┘         └────┴────┘
```

### Niri Layout Example

```toml
# ~/.hyprspace.toml

# Set Niri as default (great for horizontal workflows)
default-root-container-layout = 'scroll'  # Note: uses 'scroll' in config

[mode.main.binding]
# Optimized for horizontal navigation
cmd-h = 'focus left'
cmd-l = 'focus right'

# Resize focused window width (default 80%)
cmd-shift-minus = 'resize smart -50'
cmd-shift-equal = 'resize smart +50'

# Toggle layouts
cmd-shift-s = 'layout scroll'  # Niri layout
cmd-shift-t = 'layout tiles'
cmd-shift-d = 'layout dwindle'
```

**Niri Layout Visual:**
```
3 windows (focused on middle):
┌──┬────────────────┬──┐
│1 │       2        │3 │  ← Window 2 is focused (80% width)
│  │   (focused)    │  │     Windows 1 & 3 peek at 10% each
└──┴────────────────┴──┘

After focusing right (cmd-l):
┌──┬────────────────┬──┐
│1 │       3        │4 │  ← Window 3 now centered
│  │   (focused)    │  │     Carousel shifts smoothly
└──┴────────────────┴──┘
```

---

## Original AeroSpace Features

All original AeroSpace features are preserved:

- ✅ Tiling window manager based on [tree paradigm](https://nikitabobko.github.io/AeroSpace/guide#tree)
- ✅ [i3](https://i3wm.org/) inspired
- ✅ Fast workspaces switching without animations
- ✅ No SIP (System Integrity Protection) disabling required
- ✅ [Virtual workspaces emulation](https://nikitabobko.github.io/AeroSpace/guide#emulation-of-virtual-workspaces)
- ✅ Plain text configuration (dotfiles friendly)
- ✅ CLI first (manpages and shell completion included)
- ✅ [Proper multi-monitor support](https://nikitabobko.github.io/AeroSpace/guide#multiple-monitors)

### Layouts Comparison

| Layout | Original | This Fork | Description |
|--------|----------|-----------|-------------|
| **tiles** | ✅ | ✅ | Classic i3-style tiling |
| **accordion** | ✅ | ✅ | One maximized, others stacked |
| **dwindle** | ❌ | ✅ | Binary tree with alternating splits |
| **niri** | ❌ | ✅ | Carousel with centered focused window (use `scroll` in config) |

---

## Documentation

- 📖 [Original AeroSpace Guide](https://nikitabobko.github.io/AeroSpace/guide)
- 📜 [AeroSpace Commands](https://nikitabobko.github.io/AeroSpace/commands)
- 🎁 [AeroSpace Goodies](https://nikitabobko.github.io/AeroSpace/goodies)
- 🔧 [Default Config](https://nikitabobko.github.io/AeroSpace/guide#default-config)

### Videos

- [YouTube 91 sec Demo](https://www.youtube.com/watch?v=UOl7ErqWbrk) (original AeroSpace)
- [YouTube Guide by Josean Martinez](https://www.youtube.com/watch?v=-FoWClVHG5g)

---

## Building from Source

```bash
# Clone this fork
git clone https://github.com/YOUR_USERNAME/AeroSpace.git
cd AeroSpace

# Build debug version
./build-debug.sh

# Build release (creates both .zip and .dmg)
./build-release.sh

# Outputs:
# - .release/HyprSpace-v*.zip (full package with CLI and extras)
# - .release/HyprSpace-v*.dmg (app-only installer)
```

**Requirements:**
- macOS 13.0+ (Ventura)
- Xcode 16+ (from App Store)
- Swift 6.1+

See [dev-docs/development.md](./dev-docs/development.md) for more details.

---

## macOS Compatibility

|                                                                                | macOS 13 (Ventura) | macOS 14 (Sonoma) | macOS 15 (Sequoia) | macOS 26 (Tahoe) |
| ------------------------------------------------------------------------------ | ------------------ | ----------------- | ------------------ | ---------------- |
| AeroSpace binary runs on ...                                                   | +                  | +                 | +                  | +                |
| Centered Bar feature works on ...                                              | +                  | +                 | +                  | +                |
| Dwindle layout works on ...                                                    | +                  | +                 | +                  | +                |
| Debug build from sources is supported on ...                                   |                    | +                 | +                  | +                |
| Release build from sources is supported on ... (Requires Xcode 26+)            |                    |                   | +                  | +                |

---

## Credits & License

### Original AeroSpace
- **Author:** [Nikita Bobko](https://github.com/nikitabobko)
- **Repository:** [nikitabobko/AeroSpace](https://github.com/nikitabobko/AeroSpace)
- **License:** MIT

### Fork Enhancements
- **Centered Bar:** Inspired by [Barik](https://github.com/mocki-toki/barik)
- **Dwindle Layout:** Inspired by [Hyprland](https://github.com/hyprwm/Hyprland)
- **Author:** [BarutSRB]

### License

MIT License - Same as original AeroSpace

```
Copyright (c) 2024 Nikita Bobko (original AeroSpace)
Copyright (c) 2024-2025 [BarutSRB] (fork enhancements)
```

See [LICENSE](LICENSE) for full text.

---

## Contributing

### Merge Strategy
- Centered bar code is isolated with `// CENTERED BAR FEATURE` comments
- Dwindle layout integrates cleanly with existing layout system
- Minimal touchpoints with core AeroSpace code (~25 LOC modified)
- Easy to merge upstream changes

### Reporting Issues
- **Fork-specific features** (centered bar, dwindle): [Open an issue here](../../issues)
- **Core AeroSpace bugs**: Report to [upstream repository](https://github.com/nikitabobko/AeroSpace/issues)

---

## Support

- 💬 [Discussions](../../discussions)
- 🐛 [Issue Tracker](../../issues)
- 📧 Contact Discord: [Barut1]
- ⭐ **Star this repo** if you find it useful!

---

## Tip of the Day

From original AeroSpace:

```bash
defaults write -g NSWindowShouldDragOnGesture -bool true
```

Now you can move windows by holding `ctrl`+`cmd` and dragging any part of the window!

Source: [reddit](https://www.reddit.com/r/MacOS/comments/k6hiwk/keyboard_modifier_to_simplify_click_drag_of/)

---

## Related Projects

- [AeroSpace (Original)](https://github.com/nikitabobko/AeroSpace) - The original tiling WM
- [Hyprland](https://github.com/hyprwm/Hyprland) - Inspiration for dwindle layout
- [Amethyst](https://github.com/ianyh/Amethyst) - Another macOS tiling WM
- [Yabai](https://github.com/koekeishiya/yabai) - Advanced tiling WM
- [Rift](https://github.com/acsandmann/rift) - New emerging Rust based tiling WM

---

<div align="center">

**Made with ❤️ for the macOS power user community**
**Enjoy your enhanced AeroSpace experience! 🚀**

*If you find this useful, consider starring the repository!*

[⬆ Back to Top](#aerospace---enhanced-fork)

</div>
