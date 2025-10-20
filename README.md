# HyprSpace a Heavily Enhanced Fork of AeroSpace

<img src="./resources/Assets.xcassets/AppIcon.appiconset/icon.png" width="40%" align="right">

**AeroSpace** is an i3-like tiling window manager for macOS

*This fork adds two exclusive features: **Centered Workspace Bar** + **Dwindle Layout***

[Download Latest Release](../../releases) • [Original AeroSpace](https://github.com/nikitabobko/AeroSpace) • [Report Issues](../../issues)

---

## ✨ What's New in This Fork

This fork enhances the original AeroSpace with **two powerful features** not available upstream:

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

---

## Installation

### 📦 Download & Install

1. **Download** [AeroSpace.dmg](../../releases/latest) from the latest release
2. **Open** the .dmg file
3. **Drag** AeroSpace.app to your Applications folder
4. **First Launch Only** - Bypass Gatekeeper:
   - **Right-click** AeroSpace.app → Select **"Open"**
   - Click **"Open"** in the security dialog
   - *Alternative:* Run in Terminal:
     ```bash
     xattr -cr /Applications/AeroSpace.app
     ```
5. **Grant Accessibility Permissions** when prompted

### 🔧 Enable Features

#### Centered Workspace Bar
1. Click the AeroSpace **menu bar icon**
2. Navigate to **"Experimental UI Settings"**
3. Click **"Enable centered workspace bar"**
4. Customize settings in the same menu

#### Dwindle Layout

Add to your `~/.aerospace.toml`:

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
# ~/.aerospace.toml

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

# Build release (self-signed)
./build-release.sh --codesign-identity "-"

# Create .dmg installer
hdiutil create -volname "AeroSpace Installer" \
  -srcfolder .release/AeroSpace.app \
  -ov -format UDZO AeroSpace.dmg
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
