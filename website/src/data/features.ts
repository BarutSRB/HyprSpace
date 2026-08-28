export interface Feature {
  id: string;
  title: string;
  kicker: string;
  blurb: string;
  kbHref: string;
}

export const features: Feature[] = [
  {
    id: 'niri',
    title: 'Niri layout',
    kicker: 'Scrolling columns',
    blurb:
      'An infinite horizontal strip of columns where focus glides the camera instead of rearranging your windows. Swap windows inside a column, cycle column widths through presets, or grab any window with the mouse and resize both axes at once — the whole strip re-flows live under your hand.',
    kbHref: '/guides/layouts/',
  },
  {
    id: 'dwindle',
    title: 'Hyprland layout',
    kicker: 'Dwindle BSP',
    blurb:
      'Hyprland-style dwindle tiling: every new window bisects the focused tile along its wider axis, spiraling naturally — half, quarter, eighth. Tune split ratios, preselect where the next window lands, group tiles into tabs, and take any tile fullscreen and back with one key.',
    kbHref: '/guides/layouts/',
  },
  {
    id: 'overview',
    title: 'Overview',
    kicker: 'Every workspace at once',
    blurb:
      'Every window from every workspace flies into one searchable, zoomable view. Arrow around, send windows to other workspaces, merge them into columns, drag or close them — your whole layout is editable from above, then everything flies back to exactly where it belongs.',
    kbHref: '/features/overview/',
  },
  {
    id: 'palette',
    title: 'Command palette',
    kicker: 'Windows · menus · clipboard',
    blurb:
      'Every window, every menu item of the frontmost app, and your clipboard history behind one hotkey. Results rank by window title, then app, then workspace. Enter focuses; Shift+Enter summons the window right next to you.',
    kbHref: '/features/command-palette/',
  },
  {
    id: 'quake',
    title: 'Quake terminal',
    kicker: 'Ghostty built in',
    blurb:
      'A real terminal — Ghostty’s libghostty rendering inside OmniWM, not a wrapper around another app. One key drops it over any screen with tabs, splits, and an optional glass background — and it sticks: workspaces switch and layouts re-tile beneath it while it stays exactly where you left it.',
    kbHref: '/features/quake-terminal/',
  },
  {
    id: 'gestures',
    title: 'Trackpad gestures',
    kicker: 'Two fingers, three, four',
    blurb:
      'Swipe with 2, 3, or 4 fingers to drive the Niri strip — Snap to Columns lands you on the nearest column, or switch to Momentum for free inertial glides with rubber-band edges. Opt in to workspace swipe and another gesture flips workspaces on the monitor under your cursor, one switch per swipe.',
    kbHref: '/guides/tips/#trackpad-gestures',
  },
  {
    id: 'workspacebar',
    title: 'Workspace bar',
    kicker: 'A per-display island',
    blurb:
      'A floating island on each display that fits the MacBook notch perfectly — the active workspace docks beside the notch while the rest line up across it. Emoji-friendly chips, live app icons with focus glow, hidden-app badges, scratchpad pills, and per-monitor everything.',
    kbHref: '/features/workspace-bar/',
  },
  {
    id: 'scratchpads',
    title: 'Scratchpads',
    kicker: 'A sticky widget layer',
    blurb:
      'A floating layer above your tiles for the tools you keep reaching for — calculator, notes, music. Ten slots, each holding any number of windows, toggled with one key, restored exactly where they were — and the visible slot follows you across every workspace.',
    kbHref: '/features/scratchpads/',
  },
  {
    id: 'menuanywhere',
    title: 'Menu Anywhere',
    kicker: 'Menus at your cursor',
    blurb:
      'One hotkey pops the frontmost app’s real menu bar as a floating menu right at your pointer — every menu, every submenu, every keyboard shortcut, without traveling to the top of the screen. It is the app’s actual native menu, extracted live, so everything simply works.',
    kbHref: '/features/command-palette/#menu-anywhere',
  },
  {
    id: 'hiddenbar',
    title: 'Hidden Bar',
    kicker: 'Ice-style, built in',
    blurb:
      'Tick the apps whose menu-bar icons you never need — they vanish and the bar goes quiet. Right-click the OmniWM icon and a floating panel drops below the workspace bar with live captures of the real items; click one to use its actual menu, and everything re-hides itself seconds later.',
    kbHref: '/features/hidden-bar/',
  },
  {
    id: 'stats',
    title: 'System stats',
    kicker: 'CPU · GPU · memory · disk',
    blurb:
      'A gauge on the workspace bar opens a live readout — CPU, GPU, memory, and disk each with its own meter, plus uptime, chip, and display info in one glass popup. Drive it from the bar, a hotkey, or omniwmctl on the command line — all three toggle the same popup.',
    kbHref: '/features/workspace-bar/#system-stats',
  },
  {
    id: 'moveedge',
    title: 'Move edge',
    kicker: 'Across displays',
    blurb:
      'Your monitors become one big canvas with physical borders. At the edge of a layout, the same Move keystroke carries the window across the bezel onto the next display — layouts on both sides adapt, and focus travels with it, matching how your desk is actually arranged.',
    kbHref: '/guides/multi-monitor/#per-monitor-behavior',
  },
];

export interface ToggleTile {
  name: string;
  detail: string;
  defaultOn: boolean;
  requires?: string;
}

export const toggleTiles: ToggleTile[] = [
  { name: 'Borders', detail: 'Colored outline around the focused window', defaultOn: true },
  { name: 'Workspace Bar', detail: 'Per-display clickable workspace island', defaultOn: true },
  { name: 'Keep Awake', detail: 'Blocks idle display sleep', defaultOn: false },
  { name: 'Focus Mouse', detail: 'Focus follows mouse, no click needed', defaultOn: false },
  { name: 'Focus Edge', detail: 'Focus crosses to the adjacent display at a layout edge', defaultOn: false },
  { name: 'Mouse to Focused', detail: 'Pointer warps to the window after keyboard focus', defaultOn: false },
  { name: 'Follow Monitor', detail: 'Follow windows you move to another workspace', defaultOn: false },
  { name: 'Move Edge', detail: 'Move crosses to the adjacent display at a layout edge', defaultOn: false },
  { name: 'Mouse Warp', detail: 'Pointer crosses displays via your routing map', defaultOn: true },
  { name: 'Hide Menu Icons', detail: 'Conceal menu-bar icons, Ice-style', defaultOn: true, requires: 'macOS 27' },
];

export interface ExtraFeature {
  name: string;
  detail: string;
  href?: string;
}

export const extraFeatures: ExtraFeature[] = [
  { name: 'Live TOML reload', detail: 'settings.toml re-applies the moment you save it', href: '/config/configuration/' },
  { name: 'Hyper key', detail: 'One held key or mouse button becomes ⌃⌥⇧⌘', href: '/guides/keyboard-shortcuts/' },
  { name: 'Clipboard history', detail: 'Secure, deduplicated history inside the palette', href: '/features/command-palette/' },
  { name: 'App rules', detail: 'Route apps to workspaces, float them, size them', href: '/features/app-rules/' },
  { name: 'Native tabs', detail: 'macOS window tabs, fully managed' },
  { name: 'IPC & CLI', detail: 'Script everything with omniwmctl', href: '/reference/cli/overview/' },
];
