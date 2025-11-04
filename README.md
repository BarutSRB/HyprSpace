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

*This fork adds four exclusive features: **Centered Workspace Bar** + **Dwindle Layout** + **Niri Layout** + **Master Layout***

[Download Latest Release](../../releases) • [Original AeroSpace](https://github.com/nikitabobko/AeroSpace) • [Report Issues](../../issues)

---

## ✨ What's New in This Fork

This fork enhances the original AeroSpace with **four powerful features** not available upstream:

### 🎯 Centered Workspace Bar
A macOS integrated menu bar that displays workspace indicators and full GUI window icons **centered at the top of your screen**.

**Features:**
- 📍 Centered workspace indicators (not in system tray)
- 🪟 Window icons for each workspace
- 🖱️ Interactive: Click to focus workspace or window
- 🎨 Shows mode indicator on focused workspace
- 🔧 Highly customizable via menu:
  - Window level (Normal/Floating/Status/Popup/Screensaver)
  - Bar position (Overlapping/Below menu bar)
  - Notch-aware positioning for MacBook Pro
  - Deduplicate app icons with badge count
  - Toggle workspace numbers
  - Hide empty workspaces

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

### 🎪 Master Layout
A classic master-stack layout where one window takes the primary area and others stack in a secondary area.

**Features:**
- 🖼️ Configurable master area percentage (default 50%)
- 🔄 Flexible orientation (left master or right master)
- 📍 `promote-master` command to swap windows with master
- ⚖️ Dynamic resizing with `resize` commands
- 🎯 Ideal for focused workflows with a primary task
- 🔧 Smooth integration with existing AeroSpace commands

**Perfect for:** Code editing with reference windows, terminal + editor workflows, documentation + main window setups

---

## Installation

### 🍺 Homebrew (Recommended)

```bash
brew install --cask BarutSRB/tap/hyprspace
```

**Benefits:**
- ✅ Automatic quarantine removal
- ✅ CLI binary and app installed automatically
- ✅ Shell completions and man pages included
- ✅ Easy updates with `brew upgrade`

**After installation:**
1. Launch HyprSpace from Applications
2. **Grant Accessibility Permissions** when prompted

---

### 📦 Manual Installation

If you prefer manual installation, download from [latest release](../../releases/latest):

#### Option A: DMG Installer

1. **Download** `HyprSpace-v*.dmg`
2. **Open** the .dmg file and drag HyprSpace.app to Applications
3. **Remove quarantine** to allow the app to run:
   ```bash
   xattr -cr /Applications/HyprSpace.app
   ```
4. **Launch** HyprSpace from Applications
5. **Grant Accessibility Permissions** when prompted

#### Option B: ZIP Archive (Includes CLI)

1. **Download** `HyprSpace-v*.zip` and extract
2. **Move** `HyprSpace.app` to `/Applications/`
3. **Remove quarantine:**
   ```bash
   xattr -cr /Applications/HyprSpace.app
   ```
4. **Install CLI** (optional):
   ```bash
   # Copy CLI binary
   cp HyprSpace-v*/bin/hyprspace /usr/local/bin/

   # Install shell completion (choose your shell)
   cp HyprSpace-v*/shell-completion/zsh/_hyprspace /usr/local/share/zsh/site-functions/
   # OR for bash:
   cp HyprSpace-v*/shell-completion/bash/_hyprspace /usr/local/etc/bash_completion.d/
   # OR for fish:
   cp HyprSpace-v*/shell-completion/fish/hyprspace.fish ~/.config/fish/completions/
   ```
5. **Launch** HyprSpace and grant Accessibility Permissions

---

### ⚠️ Installing Both AeroSpace and HyprSpace

**Important:** Both AeroSpace and HyprSpace **cannot** be installed via Homebrew simultaneously.

If you want both window managers installed:

**Choose one option:**

- **Option 1:** Install HyprSpace via Homebrew + Install AeroSpace manually (.app/.dmg)
- **Option 2:** Install AeroSpace via Homebrew + Install HyprSpace manually (.app/.dmg)

Your choice depends on which window manager you want to benefit from Homebrew's automatic updates.

---

### 🔧 Enable Features

#### Centered Workspace Bar
1. Click the HyprSpace **menu bar icon**
2. Navigate to **"Experimental UI Settings"**
3. Click **"Enable centered workspace bar"**
4. Customize settings in the same menu

#### Layout Configuration
For complete configuration examples including Dwindle, Niri, Master layouts, and keybindings, see:
- **[Default Config File](docs/config-examples/default-config.toml)** - Comprehensive reference with all options

---

## Configuration

### Centered Bar Settings

All settings accessible via **Menu Bar Icon → Experimental UI Settings**:

- ✅ Enable centered workspace bar
- 🔢 Show workspace numbers
- 📊 Window Level:
  - Normal (default window level)
  - Floating (stays on top of normal windows)
  - Status Bar (same level as menu bar)
  - **Popup (above menu bar)** ← Recommended
  - Screen Saver (highest level)
- 📍 Bar Position:
  - Overlapping Menu Bar (default)
  - Below Menu Bar
- 💻 Notch-aware positioning (MacBook Pro)
- 🎯 Deduplicate app icons with badge count
- 👻 Hide workspaces with no windows

### Layout Configuration Examples

For comprehensive configuration examples including:
- **Dwindle Layout** - Binary tree tiling with automatic split direction
- **Niri Layout** - Carousel-style centered focused window
- **Master Layout** - Classic master-stack paradigm
- **All keybindings** - Complete keyboard shortcuts reference
- **All settings** - Gap sizes, margins, split ratios, and more

See the **[Default Config File](docs/config-examples/default-config.toml)** - This is the comprehensive reference with all options and detailed comments.

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
| **master** | ❌ | ✅ | Master-stack with configurable ratios |

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
git clone https://github.com/BarutSRB/HyprSpace.git
cd HyprSpace

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
- Swift 6.2+ (managed via .swift-version and swiftly)

See [dev-docs/development.md](./dev-docs/development.md) for more details.

---

## macOS Compatibility

|                                                                                | macOS 13 (Ventura) | macOS 14 (Sonoma) | macOS 15 (Sequoia) |
| ------------------------------------------------------------------------------ | ------------------ | ----------------- | ------------------ |
| HyprSpace binary runs on ...                                                   | +                  | +                 | +                  |
| Centered Bar feature works on ...                                              | +                  | +                 | +                  |
| Dwindle layout works on ...                                                    | +                  | +                 | +                  |
| Niri layout works on ...                                                       | +                  | +                 | +                  |
| Master layout works on ...                                                     | +                  | +                 | +                  |
| Debug build from sources is supported on ...                                   |                    | +                 | +                  |
| Release build from sources is supported on ...                                 |                    |                   | +                  |

---

## Credits & License

### Original AeroSpace
- **Author:** [Nikita Bobko](https://github.com/nikitabobko)
- **Repository:** [nikitabobko/AeroSpace](https://github.com/nikitabobko/AeroSpace)
- **License:** MIT

### Fork Enhancements
- **Centered Bar:** Inspired by [Barik](https://github.com/mocki-toki/barik)
- **Dwindle Layout:** Inspired by [Hyprland](https://github.com/hyprwm/Hyprland)
- **Niri Layout:** Inspired by [Niri](https://github.com/YaLTeR/niri)
- **Master Layout:** Classic tiling paradigm
- **Author:** [BarutSRB]

### License

MIT License - Same as original AeroSpace

```
Copyright (c) 2024 Nikita Bobko (original AeroSpace)
Copyright (c) 2024-2025 [BarutSRB] (fork enhancements)
```

See [LICENSE.txt](LICENSE.txt) for full text.

---

## Contributing

### Merge Strategy
- Centered bar code is isolated with `// CENTERED BAR FEATURE` comments
- Dwindle layout integrates cleanly with existing layout system
- Master layout follows existing layout patterns
- Fork adds ~2000+ lines of new feature code (CenteredBar, Dwindle, Niri, Master)
- Core integration points are minimal and clearly marked
- Easy to merge upstream changes due to clean separation

### Reporting Issues
- **Fork-specific features** (centered bar, dwindle, niri, master): [Open an issue here](../../issues)
- **Core AeroSpace bugs**: Report to [upstream repository](https://github.com/nikitabobko/AeroSpace/issues)

---

## Support

- 💬 [Discussions](../../discussions)
- 🐛 [Issue Tracker](../../issues)
- 📧 Contact Discord: [Barut1]
- ⭐ **Star this repo** if you find it useful!

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

[⬆ Back to Top](#hyprspace-a-heavily-enhanced-fork-of-aerospace)

</div>
