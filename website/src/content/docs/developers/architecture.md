---
title: Architecture Guide
description: A contributor's guide to OmniWM's internals — the four-stage pipeline, world state, layout engines, and key subsystems.
sidebar:
  order: 1
---

This guide is for contributors who want to understand OmniWM's internals. It is not a user guide or an [IPC/CLI reference](/reference/cli/overview/); for the contribution process, see [Contributing](/developers/contributing/).

**Prerequisites**: Familiarity with Swift, macOS development concepts (AppKit, AXUIElement, CGWindowID), and basic tiling window manager concepts.

---

## 1. Project Structure

### SwiftPM Targets

OmniWM is built with Swift Package Manager (Swift 6.4, strict concurrency, language mode v6). There are five production targets, one test target, and one binary target, with a clear dependency graph:

```
OmniWMApp                          (@main entry point)
└── OmniWM                         (main library)
    ├── OmniWMIPC                  (shared IPC models — zero dependencies)
    ├── OmniWMMenuBarAssertion     (Objective-C MenuBarClientCore bridge)
    ├── TOML                       (swift-toml — the only third-party package)
    └── GhosttyKit                 (binary xcframework)

OmniWMCtl                          (omniwmctl CLI)
└── OmniWMIPC

OmniWMTests                        (test target)
├── OmniWM
└── OmniWMCtl
```

| Target | Purpose | Dependencies |
|--------|---------|--------------|
| `OmniWMIPC` | Shared IPC data models and wire format | None |
| `OmniWMMenuBarAssertion` | Objective-C bridge to the private MenuBarClientCore framework (Hidden Bar concealment) | None |
| `OmniWMCtl` | CLI tool (`omniwmctl`) | OmniWMIPC |
| `OmniWM` | Core window manager library | OmniWMIPC, OmniWMMenuBarAssertion, GhosttyKit, TOML, system frameworks |
| `OmniWMApp` | Executable wrapper with SwiftUI scene | OmniWM |
| `OmniWMTests` | Test target (fixtures copied as a resource bundle) | OmniWM, OmniWMCtl |

### Source Directory Map

The `OmniWM` library (~139K LOC) is organized by pipeline stage and subsystem. Counts below are recursive
`.swift` file counts and exclude non-Swift resources (for example `IssueReporter/Prompts/*.md`):

```
Sources/
├── OmniWM/                          Main library
│   ├── App/                         Bootstrap, delegate, updater, CLI install, launch-conflict gate (6 files)
│   ├── Core/
│   │   ├── AppInfoCache.swift       App icon/name cache
│   │   ├── CommandPaletteMode.swift Command palette mode enum
│   │   ├── PrivateAPIs.swift        Private API declarations via @_silgen_name
│   │   ├── Intake/                  STAGE 1 — EventIntake, EventInterpreter, FactResolver (3)
│   │   ├── Intent/                  IntentLedger, DeadlineWheel — echo classification (2)
│   │   ├── World/                   STAGE 2 — WorldStore, the single writer (1)
│   │   ├── Reconcile/               Reducer, plans, snapshots, invariants, trace (13)
│   │   ├── Workspace/               WorkspaceManager + extensions, WindowModel, WindowState (17)
│   │   ├── Controller/              STAGE 3 — WMController, handlers, refresh pipeline (46)
│   │   ├── Ax/                      AXManager, per-app threads, frame ledger (14)
│   │   ├── Surface/                 STAGE 4 — SurfaceReconciler, WorldView, SurfaceScene (6)
│   │   ├── Border/                  Border config, applier, server-side border window (3)
│   │   ├── Spaces/                  SpaceTracker, SpaceTopology (2)
│   │   ├── Layout/
│   │   │   ├── DNode.swift          WindowToken, WindowHandle identity types
│   │   │   ├── LayoutBoundary.swift EffectPlan + layout snapshot/geometry types
│   │   │   ├── LayoutTopology.swift Read-only layout structure projection
│   │   │   ├── SideHiding.swift     Off-screen placement geometry
│   │   │   ├── Niri/                Orientation-aware scrolling-container engine (33 files)
│   │   │   └── Dwindle/             Binary-partition layout engine (5 files)
│   │   ├── Animation/               Springs, cubic easing, deceleration, viewport motion, policy (8)
│   │   ├── Config/                  SettingsStore, TOML codec, runtime state, per-monitor settings (29)
│   │   ├── Rules/                   Window rule engine and structural lookup tables (3)
│   │   ├── Input/                   Action catalog, bindings, Carbon hotkeys (14)
│   │   ├── Multitouch/              Raw multitouch frame source + gesture bindings (2)
│   │   ├── Monitor/                 Display detection, OutputId, restore assignments (6)
│   │   ├── Overview/                Expose-style workspace overview (10)
│   │   ├── Clipboard/               Clipboard history service/store/models (3)
│   │   ├── Menu/                    Menu extraction for Menu Anywhere (3)
│   │   ├── Diagnostics/             Logging, bounded recorders, runtime trace capture, health reports (41)
│   │   ├── IssueReporter/           On-device issue rewrite, GitHub URL builder, prompt Markdown (6)
│   │   ├── SkyLight/                Private SkyLight/CGS wrappers (2)
│   │   ├── Sleep/                   Sleep prevention manager (1)
│   │   ├── LockScreen/              Lock screen detection (1)
│   │   └── Support/                 Utility types & extensions (3)
│   ├── IPC/                         IPC server, connections, routing, broker (10)
│   ├── QuakeTerminal/               Drop-down terminal, Ghostty integration (14)
│   └── UI/                          SwiftUI/AppKit settings, bars, palette, status, stats (94)
├── OmniWMApp/                       2 files: @main entry + settings redirect
├── OmniWMCtl/                       8 files: CLI parser, IPC client, renderer, completion
├── OmniWMIPC/                       7 files: models, wire format, socket path, automation manifest
└── OmniWMMenuBarAssertion/          Objective-C MenuBarClientCore bridge (1 .m + 1 header)
```

### External Dependencies

OmniWM has a single third-party Swift package and otherwise builds on system frameworks:

- **`swift-toml`** — the only third-party package; used exclusively by `Core/Config/SettingsTOMLCodec.swift` to read/write `settings.toml`. The import is deliberately confined to that one file so the dependency stays swappable.
- **Key system frameworks**: AppKit/SwiftUI, Accessibility/ApplicationServices, Carbon/CoreHID, Core Graphics/Core Text/QuartzCore/ScreenCaptureKit, IOKit (including `hidsystem` and `pwr_mgt`), ServiceManagement, and os. Metal and MetalKit are link-time only — no Swift file imports them; the Ghostty surface reaches Metal through a `CAMetalLayer`.
- **SkyLight**: a private Apple framework for low-latency window-server access, linked via `-framework SkyLight` and additionally `dlopen`/`dlsym`-loaded for SLS* symbols.
- **MenuBarClientCore**: a private Apple framework dynamically loaded for macOS 27 Hidden Bar concealment; all Objective-C declarations and exception handling stay in the `OmniWMMenuBarAssertion` target.
- **FoundationModels**: weak-linked and auto-link-disabled, so the app still launches where the framework is
  unavailable. Used only by `Core/IssueReporter` for the on-device rewrite of bug reports.
- **GhosttyKit**: a local binary xcframework at `Frameworks/GhosttyKit.xcframework` (prepared outside git) providing the Quake Terminal.
- **System libraries**: libz, libc++ (required by GhosttyKit).

### Building & Running

```bash
make build                   # Ghostty preflight + arm64 Debug build
make run                     # Package, sign, and launch the bundled Debug app
make format                  # Rewrite formatting with SwiftFormat
make lint                    # Run SwiftLint
make verify                  # format-check + lint + build — the gate before a commit lands
make check                   # Alias for `make verify`
swift test                   # Default suite; live/private integration and measurement tests are opt-in
./Scripts/package-app.sh release true   # Checks, build, sign, notarize
```

`make build` first runs `Scripts/ghostty-preflight.sh`, which fails the build unless the GhosttyKit archive named in
`Scripts/build-metadata.env` exists, is arm64-only, and matches the pinned SHA-256. `make format`/`make lint` pin exact
tool versions (SwiftFormat 0.63.0, SwiftLint 0.65.1) and fail fast on any other version. SwiftFormat's `fileHeader`
rule also inserts and enforces the two-line SPDX/GPL-2.0-only header that every Swift source and test file under
`Sources/` and `Tests/` must carry; `Package.swift` is the exception, because its `swift-tools-version` directive
must stay on line one.

Live/private integration and measurement cases skip unless their explicit environment gate is set:
`OMNIWM_RUN_SKYLIGHT_LIVE_TESTS=1`, `OMNIWM_RUN_FINDER_QUICK_LOOK_TESTS=1` (with a Finder Quick Look window open),
or `OMNIWM_RUN_SURFACE_MEASUREMENTS=1`. `make test-skylight-live` runs the focused SkyLight transaction test.

Use `make run` for normal development launches. It opens the packaged Debug app through LaunchServices, preserving
the normal bundle identity; `swift run OmniWM` starts an unbundled executable. Hidden Bar's status-item behavior does
not depend on that launch style: while concealment is inactive OmniWM uses its native status item, and while
concealment is active it replaces that item with one fallback icon per display. A fallback sits beside a visible
workspace bar when possible and otherwise near the top center of the display.

---

## 2. Startup & Bootstrap

### Entry Point

The application starts in `Sources/OmniWMApp/OmniWMApp.swift`:

```
@main OmniWMApp (SwiftUI App)
  └─ @NSApplicationDelegateAdaptor → AppDelegate
       └─ applicationDidFinishLaunching()
            └─ bootstrapApplication()
                 ├─ conflict found / scan unavailable → warning → retry or quit
                 └─ clear process snapshot → launch permission check → finishBootstrap()
```

Before `finishBootstrap()` builds the runtime object graph, `bootstrapApplication()` takes a one-shot snapshot of the current user's
GUI applications and processes. Another active window manager that could issue window operations at the same time,
a second OmniWM instance, or an incomplete process inventory blocks startup to prevent conflicting window mutations.
While the warning is shown OmniWM rescans every second and dismisses the warning on its own once the interfering app
or service is gone; Check Again forces an immediate rescan. There is no bypass and no background conflict monitoring
after bootstrap succeeds.

The launch permission check requires Accessibility and Input Monitoring before bootstrap. Screen Recording is
optional and only controls capture-derived visuals.

The potentially interfering resident-manager catalog covers a second OmniWM instance plus AeroSpace, Amethyst,
bobrwm, Glide, komorebi for Mac, Nehir, Paneru, parket, Rift, Tangrid, TrimWM, yabai, and Yashiki. Dedicated
IPC/CLI clients are excluded because they cannot manage windows without their resident server; if a product
shares one executable between its server and client, a transient command can briefly match and **Check Again**
clears it after the command exits.

[PaperWM.spoon](https://github.com/mogenson/PaperWM.spoon) runs inside the generic Hammerspoon process, so the
exact-identity gate cannot detect it without blocking unrelated Hammerspoon configurations. Hammerspoon and `skhd`
are therefore not conflicts by themselves, and configuration-dependent hotkey contention is outside this startup
gate. Resident managers already running when the snapshot is taken remain detectable; launches after a successful
snapshot are outside scope.

### Boot Object Graph

`AppDelegate.finishBootstrap()` (`App/AppDelegate.swift`) builds the object graph in dependency order:

1. **`OmniWMStoragePaths.live`** — resolves config and state locations from absolute `XDG_CONFIG_HOME` /
   `XDG_STATE_HOME` overrides, falling back to `~/.config/omniwm` and `~/.local/state/omniwm`.
2. **`RuntimeStateStore`** — JSON store for non-settings runtime state (`runtime-state.json`).
3. **`SettingsStore`** — `@MainActor @Observable`, loaded from `settings.toml` in the resolved config directory.
   `UserDefaults` is not used for settings; TOML is the single source of truth. `SettingsTOMLCodec` first reads the
   raw TOML tree, version-gates it, applies each required schema migration in memory, then strictly decodes the current
   canonical schema. A successful known-version upgrade secures the exact original bytes in a write-once pre-version
   backup and atomically rewrites only the final canonical file; valid migrations never use invalid-file recovery
   slots. An unsupported future version remains untouched and blocks settings writes. Structured configuration notices
   cover startup, live reload, and save-time races through one
   `SettingsStore` transition path, so diagnostics update only when the notice actually changes.
4. **`HiddenBarController`** — per-app menu-bar concealment (assessment-mode assertion, hidden-icons panel).
5. **`WMController`** — central coordinator (see [4.1](#41-wmcontroller--the-coordinator)); passed the clipboard-history directory.
6. **`AppCLIManager`** and **`UpdateCoordinator`** — CLI exposure plus GitHub release polling/popup.
7. **`FatalCapture.install` / `consumePending`** — configure the diagnostic context used by the explicit `fatal()` /
   `fatalOffMain()` shims and hand the newest pending `omniwm-crash-*.log` from the previous run to `WMController`.
8. **`StatusBarController`** — menu-bar UI and manual update checks.
9. **`IPCServer`** — started only if `ipcEnabled` is set.
10. **Automatic update checks** — started after the rest of the core bootstrap succeeds.
11. **Launch and monitor-setup presentation** — starts monitor-readiness observation, plays the per-display
    `LaunchOverlayController`, then evaluates whether to present the monitor setup guide after the overlay finishes.

`FatalCapture` is not a process-wide Swift trap handler. Preconditions, force unwraps, Core Foundation ownership
faults, and other raw traps bypass those explicit shims. GhosttyKit's embedded crash handler can instead write a
Sentry/breakpad envelope to `~/.local/state/ghostty/crash/<uuid>.ghosttycrash` for a silent signal crash.

`applicationWillTerminate` tears down the status bar and Hidden Bar assessment assertion, stops window-management
services, flushes the window-restore catalog, settings, and runtime state, then stops the IPC server.

### Service Startup

`WMController.setEnabled(true)` drives `ServiceLifecycleManager.start()`:

1. Polls for accessibility permission (blocks until granted).
2. Once trusted, `startServices()` connects all event plumbing:
   - `eventIntake.open(sink: eventInterpreter)` — opens the intake buffer and wires the drain sink.
   - `spaceTracker.start()` — begins space-topology tracking.
   - `AXEventHandler` setup — SkyLight/CGS event observation via `CGSEventObserver`.
   - `HotkeyCenter` — Carbon hotkey registration.
   - `MouseEventHandler` — CGEvent taps.
   - `DisplayConfigurationObserver` — display reconfiguration.
   - App activation/termination/hide/unhide observers and `NSWorkspace.activeSpaceDidChangeNotification` (which posts `.activeSpaceChanged` into the intake).
   - An initial full-rescan refresh.

---

## 3. Core Mental Model

### 3.1 The Four-Stage Pipeline

OmniWM's main window-manager path is fundamentally **reactive**. Runtime events and semantic commands that can
change semantic world state converge on a four-stage pipeline with exactly one semantic mutation point. This is
not a claim that every IPC operation or timer enters `EventIntake`: read-only queries and direct asynchronous
capture control bypass it because they do not mutate window-manager world state.

```
┌──────────────────────────────────────────────────────────────────────┐
│  TRANSPORTS                                                            │
│  CGSEventObserver (SkyLight)   HotkeyCenter (Carbon)   MouseEventHandler│
│  per-app AXObservers           IPCApplicationBridge    DeadlineWheel   │
│  DisplayConfigurationObserver  FactResolver            ServiceLifecycle │
└───────────────────────────────┬──────────────────────────────────────┘
                                 │  EventIntake.post(IntakeEvent)
                                 v
┌───────────────────────────────────────────────────────────────────────┐
│  STAGE 1 — INTAKE   (Core/Intake, Core/Intent)                         │
│  EventIntake: one lock-guarded ordered buffer, monotonic global seq,   │
│    coalesces mouse/CGS-frame bursts, drains ONCE per cycle via         │
│    CFRunLoopPerformBlock on the main run loop.                         │
│  EventInterpreter: the drain sink — a pure switch that DISPATCHES each │
│    stamped event to the owning WMController sub-handler.               │
│  IntentLedger: classifies AX focus echoes (echoOf / lateEcho /        │
│    external) so our own actions aren't mistaken for the user's.       │
│  FactResolver: gathers activation-focus and deferred AX window        │
│    constraint facts off-main, then re-enters the intake.              │
└───────────────────────────────┬──────────────────────────────────────┘
                                 │  WorkspaceManager.recordReconcileEvent(WMEvent)
                                 v
┌───────────────────────────────────────────────────────────────────────┐
│  STAGE 2 — WORLD   (Core/World, Core/Reconcile, Core/Workspace)        │
│  WorldStore.commit(WMEvent): the SINGLE synchronous writer.           │
│    EventNormalizer → StateReducer (pure) → resolve → InvariantChecks. │
│    Owns WindowModel, focus, viewports, monitor sessions, space        │
│    topology, and BOTH layout engines — all private; seq is bumped.    │
│    Output: an ActionPlan (state deltas).                              │
└───────────────────────────────┬──────────────────────────────────────┘
                                 │  requestRelayout(reason:) / EffectPlan
                                 v
┌───────────────────────────────────────────────────────────────────────┐
│  STAGE 3 — EFFECTOR   (Core/Controller, Core/Ax, Core/Layout)         │
│  LayoutRefreshController: schedules/coalesces refreshes, drives the    │
│    engines under a build scope to build an EffectPlan, drops stale    │
│    plans via seq/InvalidationMarks, executes frame diffs.            │
│  AXManager → AppAXContext: writes CGRects on per-app run-loop threads.│
│  AXFrameApplicationLedger: dedup / verify / retry / convergence.     │
└───────────────────────────────┬──────────────────────────────────────┘
                                 │  noteWorldChanged()
                                 v
┌───────────────────────────────────────────────────────────────────────┐
│  STAGE 4 — SURFACE   (Core/Surface, Core/Border)                      │
│  SurfaceReconciler: derives every auxiliary surface (focus border,    │
│    workspace bars, tab rails, native-fullscreen placeholders, and     │
│    parking-edge masks) from a read-only WorldView facade, diffs       │
│    against the applied scene, and applies only what changed.         │
└───────────────────────────────────────────────────────────────────────┘
```

Two properties are load-bearing:

- **One buffer, one drain, one writer.** Transports participating in the semantic world-state pipeline enqueue into a
  single `EventIntake` buffer that drains once per main-run-loop cycle in seq order; semantic model, focus,
  workspace, and layout-engine mutation flows through `WorldStore.commit`. Sub-handlers never mutate that state
  directly.
- **The interpreter dispatches; it does not classify or commit.** `EventInterpreter` is a pure switch that routes each `IntakeEvent` to a `WMController` sub-handler. Echo classification lives in `IntentLedger`; commits happen in `WorldStore` reached via `WorkspaceManager.recordReconcileEvent`.

### 3.2 Window Identity

Windows are identified at three levels, each serving a different purpose:

```swift
// 1. WindowToken — value type, used as dictionary keys everywhere
//    Core/Layout/DNode.swift
struct WindowToken: Hashable, Sendable {
    let pid: pid_t       // Process ID
    let windowId: Int    // SkyLight/CGS window ID
}

// 2. WindowHandle — reference type, identity-compared (===)
//    Core/Layout/DNode.swift
final class WindowHandle: Hashable {
    var id: WindowToken              // re-pointed on rekey
    // hash/equality use ObjectIdentifier (reference identity)
}

// 3. AXWindowRef — accessibility bridge to the actual window
//    Core/Ax/AXWindow.swift
struct AXWindowRef: Hashable, @unchecked Sendable {
    let element: AXUIElement   // Accessibility handle for read/write
    let windowId: Int          // equality/hash by windowId only
}
```

**Why three layers?**

- `WindowToken` is a lightweight `Sendable` value type that survives relayouts and works as a dictionary key without holding any AX resource. When an app destroys and recreates a window, `WindowModel.rekeyWindow` re-points everything from the old token to the new one so identity is preserved.
- `WindowHandle` provides reference identity for layout-tree holders; it is re-pointed during rekey so a holder keeps a stable handle even as the token changes.
- `AXWindowRef` is the bridge to the macOS Accessibility APIs and holds the heavyweight `AXUIElement`. It is stored on `WindowState.axRef`.

### 3.3 Window Lifecycle

**Creation** (see the full trace in [5.2](#52-external-window-event-flow)):

1. `CGSEventObserver` receives `.created(windowId, spaceId)` from SkyLight and posts `.cgs(...)` into `EventIntake`.
2. After the drain, `EventInterpreter` routes it to `AXEventHandler.handleCGSEvent` → `handleCGSWindowCreated` → `processCreatedWindow` → `trackPreparedCreate`, which reads AX attributes and runs the rules.
3. `WindowRuleEngine.decision(for:token:appFullscreen:)` produces a `WindowDecision` (`.managed` / `.floating` / `.unmanaged` / deferral).
4. If tracked, `WorkspaceManager.addWindow` calls `recordReconcileEvent(.windowAdmitted(...))`, which commits the event through `WorldStore`. The commit `upsert`s the window into the private `WindowModel`, reduces to an `ActionPlan`, and runs invariants.
5. `AXEventHandler` then calls `layoutRefreshController.requestRelayout(reason: .axWindowCreated, ...)` to schedule the effector.

**Destruction:**

1. `CGSEventObserver` / per-app AX observer reports the window gone; the event drains to `AXEventHandler`.
2. A `.windowRemoved` commit removes the entry from `WindowModel` and the engine node.
3. `requestRelayout` (route `windowRemoval`) re-lays out and runs focus recovery if the destroyed window was focused.

**Managed Replacement:**

Some apps (Ghostty, browsers) destroy and recreate windows during internal operations. `AXEventHandler` correlates a destroy+create pair via `ManagedReplacementMetadata` and emits a `.windowRekeyed` event so the new window inherits the old one's workspace, mode, and position instead of being admitted fresh. A full rescan that intersects an existing correlation burst awaits its already-armed grace task before taking the enumeration snapshot. It does not cancel the burst or shorten the grace interval, so an unmatched close is replayed before enumeration while a create arriving inside the interval can still preserve the original identity. When an untracked full-rescan candidate is the exact live target of a non-exhausted identity-rebind retry, the authoritative source token remains preserved until the rebind settles. Target destruction, retry exhaustion, source disappearance or incarnation change, and any target token or AX-identity mismatch fall through to normal admission and retirement.

`WorldStore` applies managed-window identity and Space-membership lifecycle changes together. Definitive removal deletes the window's membership, while rekey transfers membership only when the old Space still exists in the current topology and the replacement has no newer membership observation. Transient destroy/close correlation therefore cannot erase the evidence needed to distinguish native fullscreen suspension from authoritative retirement.

**Workspace placement:**

`PlacementResolver` applies continuity before fresh placement: automatic readmission keeps the existing workspace, structural replacements keep their original workspace and identity, and unique persisted boot-restore matches retain restore authority. A valid workspace rule is the initial default only while that running app instance has no tracked window; explicit rule application can still move existing windows. Later tiled and parentless floating live creates use a pending managed-focus destination and the interaction workspace captured when the create event arrived before mode-specific native-Space, focus, and frame fallbacks. Finder Quick Look is the narrow exception: native-Space and same-process tiled-window spawn placement remain ahead of interaction so its macOS focus churn cannot redirect the preview. Contextless startup and full-rescan discovery remain conservative and frame-distributed.

### 3.4 Stage 2 — WorldStore, the Single Writer

`WorldStore` (`Core/World/WorldStore.swift`) is the heart of the architecture: the **only** path that mutates window-manager state. It is `@MainActor` and owns, as private properties, everything that constitutes the "world":

```swift
@MainActor final class WorldStore {
    private let model = WindowModel()              // per-window registry (private!)
    private(set) var seq: UInt64 = 0               // monotonic mutation counter
    private(set) var focus = FocusSessionSnapshot()
    private(set) var viewports: [WorkspaceDescriptor.ID: ViewportState] = [:]
    private(set) var scratchpadMembers: [ScratchpadIndex: [WindowToken]]
    private(set) var revealedScratchpad: ScratchpadIndex?
    private(set) var hiddenAppPIDs: Set<pid_t> = []
    private var appVisibilityGenerationByPID: [pid_t: UInt64] = [:]
    private(set) var monitorSessions: [Monitor.ID: MonitorSession] = [:]
    private(set) var spaceTopology = SpaceTopology()
    private(set) var niriEngine: NiriLayoutEngine?      // layout engines are
    private(set) var dwindleEngine: DwindleLayoutEngine? //   PRIVATE to the world
    // ... InvalidationMarks bookkeeping
}
```

**The commit pipeline.** `commit(_:monitors:snapshot:resolvePlan:)` is **synchronous**. Each call:

1. Bumps `seq` (`seq &+= 1`).
2. Applies the window mutation in the `.beforePlan` phase (e.g. `model.upsert`).
3. Runs `EventNormalizer.normalize` (fills missing monitor/workspace/from fields from the existing entry).
4. Runs `StateReducer.reduce(event:existingEntry:currentSnapshot:monitors:)` — a **pure** function — to produce an `ActionPlan`.
5. Lets the caller resolve/augment the plan (`resolvePlan`), then applies any `.afterPlan` mutation.
6. Runs `InvariantChecks.validate(snapshot:)` on the committed snapshot.
7. Records a `ReconcileTxn` into the private `ReconcileTraceRecorder` (a bounded 256-entry ring included in runtime diagnostics and capture reports).

**Reads vs. writes.** `WorldStore` exposes a large read-accessor surface (`entry(for:)`, `windows(in:)`, `focus`, …) that delegates to the private `WindowModel`. Semantic model, focus, workspace, and layout-engine mutators are guarded by `assertInCommit` (`commitDepth > 0`). Invalidation watermark/sequence bookkeeping has explicit `noteInvalidation` paths outside commit, while the high-frequency animation tier is the separate exception described in [§3.9](#39-the-ungated-animation-tier).

**macOS application visibility.** App hiding is PID-scoped world state, owned by `WorldStore.hiddenAppPIDs` and changed only by `.hiddenApplicationsChanged` commits. `appVisibilityGenerationByPID` advances on every visibility transition or explicit invalidation so delayed reveal intents can reject stale work. This state is orthogonal to per-window `LayoutReason` (`standard` / `nativeFullscreen`) and `HiddenState` (workspace parking, layout-transient hiding, or scratchpad): hiding an app masks its windows from layout projection without destroying their durable layout identity or fullscreen state.

**macOS application visibility diagnostics.** An active runtime capture records the ordered NSWorkspace notification, intake dispatch, authoritative generation change, AX hard-fence transition, visibility-refresh lifecycle, and explicit reveal-intent result in the bounded `AppVisibilityTrace`. The capture's start/end reports independently compare WorldStore visibility, AX suppression, macOS process visibility, pending reveal intent, per-window fullscreen/parking state, and the Niri/Dwindle projection masks. These are read-only observations rather than another visibility authority; detailed records are capture-gated, and no layout, animation, AX-write, or SkyLight hot loop performs visibility trace work.

**Engine mutation sanction.** The two layout engines are private to the world. They may only be mutated when `isEngineMutationSanctioned` is true — i.e. inside `commit`. Callers not already inside a commit enter one through the `WorkspaceManager` scope wrappers: `withEngineMutationScope { … }` for ad-hoc engine mutations, and `withBatchedLayoutBuild { … }` for plan-building (Stage 3), which calls into the engines (`syncWindows`/`removeWindows`/`restoreInitialPlacements`) inside a single `layout_build` commit. `commit` sets each engine's `isMutationSanctioned` flag and the engines assert on any out-of-scope mutation.

**Staleness machinery (`InvalidationMarks`).** Plan-building itself is synchronous inside the `layout_build` commit. After that commit returns, a newer relevant commit or explicit invalidation can still land before effect application, post-layout work, or animation acceptance. `WorldStore` tracks per-domain seq watermarks (`workspace` / `layout` / `focus` / `fullscreen`) via `noteInvalidation(...)`. The effector stamps each plan with a `plannedSeq` and calls `isSeqCurrent(plannedSeq, for:domains:)` before applying; a plan older than a relevant mutation is dropped rather than applied stale.

**Invariants.** `InvariantChecks.validate` returns ungraded `ReconcileInvariantViolation` values. Any non-empty result is added to the transaction notes and per-code counters and triggers `assertionFailure` in Debug builds. Layout-token and selection checks are hard assertions like the rest; there is no trace-only severity tier.

### 3.5 Stage 3 — The Effector & Refresh Pipeline

`LayoutRefreshController` (`Core/Controller/LayoutRefreshController.swift`) is the effector: it turns world state into actual window frames.

**Scheduling.** It owns a single-slot scheduler (`activeRefresh` + `pendingRefresh`): if a refresh is in flight, incoming requests merge into the pending slot and fire when the active one completes. Each `RefreshReason` (`Core/Controller/RefreshReason.swift`) maps to a `RefreshRequestRoute` and a per-reason debounce policy.

| Route | When | What it does |
|-------|------|--------------|
| `fullRescan` | Startup/global fallback, app launch/rebind recovery, space/wake/display inventory | Global or scope-limited enumeration + relayout |
| `relayout` | Config change, app termination, window created, frame changed | Recompute from current state (debounced) |
| `immediateRelayout` | Commands, gestures, workspace switch | Synchronous relayout |
| `visibilityRefresh` | App hidden/unhidden | Reproject active affected layouts while preserving durable layout topology |
| `windowRemoval` | Window destroyed | Remove + relayout + focus recovery |

**Inventory scope and authority.** Startup, app-rule reevaluation, and incomplete scoped evidence retain the global inventory path. App launch and identity/binding recovery enumerate only the affected app PIDs. Active-Space changes enumerate the newly active native Spaces plus exact managed windows previously or currently known on those Spaces. If a fullscreen Space disappears between the baseline and stable topology, its previously mapped managed windows remain exact scoped targets, but the vanished Space itself is not queried and the scan does not widen to every window owned by those PIDs. Wake, unlock, and display changes apply each first usable topology sample immediately for frame-write safety by carrying forward known membership without issuing per-window membership queries, while deferring native-fullscreen lifecycle reconciliation. A matching second sample performs one membership-query pass, preserves last-known membership when a private query is inconclusive, and reconciles fullscreen state before issuing one coalesced scoped inventory. For each requested native Space, `SLSCopyWindowsWithOptionsAndTags` supplies raw membership. OmniWM deduplicates those IDs and performs one initial bulk WindowServer detail query; targeted reconciliation can issue additional bulk queries for preserved managed IDs and AX-discovered dependency windows. AX work is limited to selected application roots, although each selected root still enumerates `kAXWindows` and resolves WindowServer IDs before filtering.

A scoped scan may update missing-window counters only for explicit app roots whose AX enumeration and identity dependencies succeeded. Unrelated windows retain their existing counters and bindings. `LayoutRefreshController.LayoutState` owns these transient observations keyed by stable `WindowHandle` identity, so rekeys preserve an observation while a same-token reincarnation starts clean. Observing or resetting them does not mutate `WorldStore`, create a semantic reconcile transaction, advance world sequence, rebuild snapshots, or emit trace records. Missing windows still require two consecutive authoritative observations; the first scoped miss schedules one delayed confirmation of the same scope. A failed or unavailable native-Space query promotes the request to the global safety path rather than treating an unknown inventory as empty.

Scoped reconciliation reduces application-root enumeration and full AX-fact work relative to a global scan; it does not make refresh proportional only to changed windows. Topology refresh still checks native-Space membership for each tracked managed window, and selected AX roots still enumerate their window lists. Its latency and allocation benefit remains unproven until measured.

**Plan-building runs inside a commit.** `buildRelayoutEffectPlan` calls `NiriLayoutHandler.layoutWithNiriEngine` (and the Dwindle equivalent), which run `syncWindows`/`removeWindows`/`restoreInitialPlacements` on the engines inside `workspaceManager.withBatchedLayoutBuild` — a single synchronous `layout_build` commit that also stamps each plan's `plannedSeq`. The layout engines return raw `[WindowToken: CGRect]` frame maps; the handlers wrap those into a `WorkspaceLayoutPlan` → `WorkspaceLayoutDiff` → `EffectPlan` (`Core/Layout/LayoutBoundary.swift`).

**Monitor geometry has three explicit frames.** `LayoutMonitorSnapshot` carries a normal `workingFrame`, a `borderSafeFillFrame`, and a `fullscreenLayoutFrame`. When focus borders are enabled, `WMController` rounds the configured border width upward to a physical pixel and floors the runtime inner gap plus each final normalized outer strut to that clearance. Raw global and per-monitor settings are not rewritten; Dwindle's monitor-local `useGlobalGaps = false` path passes through the same runtime resolver. Normal tiled and valid custom-fit windows use `workingFrame`; Niri maximized windows and Niri/Dwindle single-window fill use `borderSafeFillFrame`; true layout fullscreen remains borderless and uses `fullscreenLayoutFrame` unchanged.

**Frame application.** `executeEffectPlan` hands each plan's diff to `LayoutDiffExecutor`, which calls `AXManager.applyFramesParallel`. Only after the plan's sequence is accepted, its workspace-scoped `nativeFullscreenSlots` projection is handed directly to `SurfaceReconciler`; settled plans also schedule the normal Stage 4 scene reconciliation.

### 3.6 Stage 4 — Surface Reconciliation

Auxiliary UI — the focus border, per-monitor workspace bars, shared Niri/Dwindle tab rails, native-fullscreen placeholder panels, and parking-edge masks — is no longer pushed ad hoc by individual managers. `SurfaceReconciler` (`Core/Surface/SurfaceReconciler.swift`) derives all of it in one place:

1. State-mutating paths request either a full-scene reconcile or a border-only reconcile. External focus-owner projection, floating border geometry, suppression, system-modal state, restack, color, and display-scale changes take the border-only route. Managed selection changes remain full-scene because workspace bars and native-fullscreen placeholders also consume that state. A coalesced full-scene request always wins. Both scopes drain through one `CFRunLoopPerformBlock` on the main run loop.
2. On a full drain, `runFullReconcile` builds a fresh `WorldView` (a read-only facade over the world), and `SurfaceDerivation.derive` produces a `DesiredSurfaceScene` (optional border, tab rails, placeholders, bars, and `parkingEdgeMasks`). The border-only route derives and applies only the border while retaining the other applied surfaces. A forced restack additionally re-applies ordering to the already-derived tab rails and native-fullscreen placeholders without rebuilding their desired state.
3. The desired scene is diffed (by value equality) against the last applied scene; only changed surfaces are touched, routed to `BorderSurfaceApplier`, `WorkspaceBarManager.apply(_:)`, `TabRailManager`, `NativeFullscreenPlaceholderManager`, and `ParkingEdgeMaskManager`.

Native-fullscreen placeholders have a split projection. `WorldView` derives stable lifecycle/content descriptors from every fullscreen record, including hidden descriptors retained through workspace switches and temporary entry loss. Niri and Dwindle attach exact rendered slot frames and layout visibility to each accepted `WorkspaceLayoutDiff`: Niri uses its current frame map plus `hiddenHandles`; Dwindle uses its interpolated frame map and active group member. `SurfaceReconciler` joins the two by `record.originalToken`, validates the current token, and uses the geometry-only move path only when token, workspace, selection, and visibility state are unchanged. This avoids rereading engine side effects, keeps rejected plans away from AppKit, and prevents the applied scene from advancing beyond the actual panel state.

The reconciler is *not* called from inside `WorldStore.commit`; it reads current state at drain time through a freshly constructed `WorldView`, not a captured commit snapshot.

### 3.7 Echo Classification & Intents

When OmniWM activates an app or focuses a window, macOS emits an AX focus-changed event — an *echo* of our own action. Without bookkeeping, the system can't tell that echo apart from the user genuinely clicking another window. The Intent subsystem (`Core/Intent/`) solves this.

- **`IntentLedger`** is a `@MainActor` ring buffer (capacity 256) of `Intent` records. `IntentKind` has seven cases: `activateApp`, `appTerminationFocusRecovery`, `appRevealFocus`, `focusPolicyLease`, `focusWindow`, `replacementFocus`, `sameAppCloseProbe`. `appRevealFocus` carries the exact window-handle identity, a pending PID-to-visibility-generation map, focus watermark and fingerprint, plus a normal-window, scratchpad-slot, or exact scratchpad-member destination so unhide completion cannot focus stale state. `appTerminationFocusRecovery` correlates a focused floating app's termination with macOS's fallback activation long enough to restore the workspace's retained tiled focus without accepting a transient fallback application. Each record carries the global intake `seq` at issue time, a lifecycle `phase` (`pending`/`confirmed`/`superseded`/`expired`/`cancelled`), and retry state.
- **`classifyFocusObservation(token:)`** returns an `EchoClassification`: `.echoOf(intent)` when an open intent targets the token, `.lateEcho(intent)` when a recently-retired intent (within a 1-second window) matches, otherwise `.external`. The consumer is `AXEventHandler`, which treats `.echoOf`/`.lateEcho` as confirmation of our pending request and only processes `.external` as a genuine user focus change.
- **`DeadlineWheel`** is a main-actor timing wheel keyed by `IntentID`: it arms a single `Task` that sleeps until the nearest deadline, then posts `.intentExpired(intentId:)` back into `EventIntake` (it does not fire callbacks). `AXEventHandler.handleIntentExpired` decides what to do — e.g. a still-active `focusWindow` intent drives a focus *retry* rather than expiring. Activation-settle deadlines are 100ms; an `appRevealFocus` intent expires after 2 seconds; app-termination recovery uses a one-turn verification followed by a bounded 600ms fallback barrier. The `DeadlineWheel` serves focus/activation/lease/reveal/recovery intents only; AX frame-write retries are a separate mechanism (see [4.9](#49-accessibility-layer)).
- **`FactResolver`** gathers two AX fact families that should not block the main actor: focused-window activation facts (including fullscreen/system-modal classification) and deferred window size constraints. It uses the app's `AppAXContext.axThread` when available or its dedicated shared resolver thread as a fallback, then re-enters the pipeline through `.activationFactsResolved` or `.windowConstraintsResolved`.

### 3.8 Layout Engines as Pure State Machines

Both engines follow the same contract:

1. They own their own **tree state** — per-workspace `NiriRoot` trees for Niri, per-workspace `DwindleNode` trees for Dwindle.
2. They are **owned privately by `WorldStore`** and may only be mutated under commit/build-scope sanction.
3. Given a workspace's snapshot, monitor geometry, gaps, and (for Niri) a `ViewportState`, they compute a `[WindowToken: CGRect]` frame map.
4. They **never touch windows** — no AX calls, no frame writes, no `@Observable`, no actor isolation. They are plain `final class` types that run on the main actor only because their owner does.

The Controller-layer handlers (`NiriLayoutHandler`/`DwindleLayoutHandler`) translate the engines' frame maps into `EffectPlan`s; the engines themselves never build an `EffectPlan`. Note that `ViewportState` is stored in `WorldStore.viewports`, not inside the Niri engine — the engine receives it as a call parameter.

### 3.9 The Ungated Animation Tier

There is one deliberate exception to "all mutation goes through commit": **per-frame animation**.

`LayoutRefreshController` owns a `CADisplayLink` per display (via `NSScreen.displayLink(target:selector:)`). On each tick (`displayLinkFired`, at `displayLink.targetTimestamp`) it fans out to `NiriLayoutHandler.tickScrollAnimation`, the Dwindle tick, closing animations, and `surfaceReconciler.reconcileAnimationTick`. These ticks advance spring/gesture math and push interpolated frames to AX **outside `WorldStore.commit`** — committing 60–120 times per second would be both wasteful and impossible (commit is synchronous and seq-bumping). The committed `ViewportState` offset is the *anchor*; the animation adds a transient delta on top. When motion settles, the handler finalizes and stops the display link.

`AnimationDriver` (`Core/Animation/`) owns only the per-workspace viewport scroll motion — its `ViewportMotion` is `gesture`, `spring`, or `deceleration`. Per-window and per-column animations live inside `NiriLayoutEngine` (`tickAllWindowAnimations`/`tickAllColumnAnimations`); Dwindle node animations use `CubicAnimation`.

### 3.10 Thread Safety Model

**`@MainActor` is the default.** Nearly everything — UI, event handling, layout computation, the world, the reconciler — runs on the main actor.

**Exceptions, all explicitly bounded:**

- **Per-app AX threads.** `AppAXContext` runs a dedicated `NSThread` + `CFRunLoop` per application. All `AXUIElement` reads/writes for that app happen there. State pinned to the thread is wrapped in `ThreadGuardedValue` and checked against a `@TaskLocal appThreadToken` (a `precondition` in debug). The bridge back to the main actor is `Thread.runInLoop` (async/await + `CheckedContinuation`, 2-second timeout).
- **The intake buffer.** `EventIntake` holds its buffer in a `nonisolated OSAllocatedUnfairLock`, so `EventIntake.post(...)` is callable from any transport thread; the drain re-enters the main actor via `CFRunLoopPerformBlock` + `MainActor.assumeIsolated`.
- **IPC actors.** `IPCApplicationBridge`, `IPCConnection`, `IPCEventBroker`, and `IPCConnectionRegistry` are Swift actors; they hop to `@MainActor` for any window-management work.
- **Clipboard store.** `ClipboardHistoryStore` is a Swift actor; pasteboard reads happen on a utility `DispatchQueue`.

---

## 4. Key Subsystems

### 4.1 WMController — The Coordinator

**File:** `Sources/OmniWM/Core/Controller/WMController.swift`

`WMController` is a `@MainActor @Observable` coordinator. After the redesign it owns the *plumbing* and the *handlers*, but **not** the window-manager state — that lives behind `WorkspaceManager` → `WorldStore`. Its job is wiring callbacks, applying settings, resolving workspace placement for new windows, and being the host object every lazy sub-handler captures as `controller: self`.

**Pipeline objects it owns:** `eventIntake`, `eventInterpreter`, `factResolver`, `intentLedger`, `deadlineWheel`, `spaceTracker`, `surfaceReconciler`.

**Sub-handlers it owns:**

| Handler | Responsibility |
|---------|---------------|
| `axEventHandler` | CGS/AX events → admissions, focus confirm/retry, native-fullscreen detection |
| `commandHandler` | Routes physical `HotkeyInvocation`s through Overview first, then routes inactive-Overview commands with layout-compatibility guards |
| `mouseEventHandler` / `mouseWarpHandler` | CGEvent tap, focus-follows-mouse, gestures; cursor warp |
| `workspaceNavigationHandler` | Workspace switching, directional whole-workspace monitor moves, explicit-handle window workspace/monitor transfers, and Niri whole-column workspace transfers |
| `windowActionHandler` | Close, fullscreen, float toggle |
| `serviceLifecycleManager` | Observer setup, permission polling, service start/stop |
| `layoutRefreshController` | Refresh scheduling, the display-link loop, frame application (owns `niriLayoutHandler`/`dwindleLayoutHandler`) |
| `focusNotificationDispatcher` | Publishes focus-change events to IPC subscribers |

**Core managers it owns directly:** `settings: SettingsStore`, `workspaceManager: WorkspaceManager`, `axManager: AXManager`, `windowRuleEngine: WindowRuleEngine`, `hotkeys: HotkeyCenter`, `motionPolicy: MotionPolicy`, `animationClock: AnimationClock`, plus surface managers (`workspaceBarManager`, `nativeFullscreenPlaceholderManager`) and the quake, clipboard, command-palette, and system-stats controllers. `OverviewController` is **not** one of them: `windowActionHandler` lazily constructs and owns it, and `WMController` reaches Overview through that handler.

:::note
The layout engines are **not** owned by `WMController`. `WMController.niriEngine`/`dwindleEngine` are pass-through accessors that ultimately reach `WorldStore`'s private engines.
:::

### 4.2 World State: WorldStore, WorkspaceManager, WindowState

**`WorkspaceManager`** (`Core/Workspace/WorkspaceManager.swift`) is the authoritative state facade. It owns the only `WorldStore` instance (`private let world = WorldStore()`), the workspace descriptors (`workspacesById` / `workspaceIdByName`), the monitor list, active workspace and interaction-monitor state, remembered workspace focus, gaps, the native-fullscreen record store, and the persisted-restore catalog. It exposes the commit entry point and a large derived-read surface, and emits `onSessionStateChanged` / `onRuntimeInvalidation` / `onGapsChanged`. Its `onWindowRemoved` notification is emitted only after authoritative managed-window removal.

```
WorkspaceManager
├── workspacesById / workspaceIdByName          Workspace descriptors (id = UUID)
├── monitors + indexes, gaps / outerGaps
├── nativeFullscreenRecordsByOriginalToken      Native-fullscreen records
├── bootPersistedWindowRestoreCatalog           Relaunch restore intent
└── world: WorldStore  (private)                THE single writer
    ├── model: WindowModel  (private)           [WindowToken: WindowState]
    ├── focus: FocusSessionSnapshot             focused token, pending managed focus, …
    ├── viewports: [WorkspaceID: ViewportState] Niri scroll/selection per workspace
    ├── monitorSessions: [MonitorID: MonitorSession]   visible workspace per monitor
    ├── scratchpadMembers: [ScratchpadIndex: [WindowToken]]
    ├── revealedScratchpad: ScratchpadIndex?
    ├── hiddenAppPIDs + visibility generations    PID-scoped macOS app visibility
    ├── spaceTopology: SpaceTopology
    └── niriEngine / dwindleEngine  (private)   layout trees, mutation-gated
```

**`WorldStore.commit` is the semantic world-state and layout-engine mutation path**, entered through `WorkspaceManager.recordReconcileEvent(_ event: WMEvent)` (which supplies the snapshot/resolve closures and writes the resolved `ActionPlan` back through the in-commit mutators). Invalidation bookkeeping and the animation tier remain the explicit exceptions described above.

**`WindowModel`** (`Core/Workspace/WindowModel.swift`) is a reference-type per-window registry — but it is now **private to `WorldStore`**, not a shared source of truth. It stores one `WindowState` per `WindowToken` plus reverse indexes (`windowIdToToken`, `tokensByWorkspace`, `tokensByWorkspaceMode`, `tokensByPid`) and constraint/min-size caches. Missing-detection counters are transient reconciliation state owned by `LayoutRefreshController.LayoutState`, as described in [Stage 3](#35-stage-3--the-effector--refresh-pipeline), and do not enter `WorldStore` commits.

**`WindowState`** (`Core/Workspace/WindowState.swift`) is the per-window record — a `struct` (the old nested `WindowModel.Entry` is gone):

```swift
struct WindowState: Equatable {
    let token: WindowToken
    let axRef: AXWindowRef
    var workspaceId: WorkspaceDescriptor.ID
    var mode: TrackedWindowMode                 // .tiling or .floating
    var lifecyclePhase: WindowLifecyclePhase
    var observedState: ObservedWindowState
    var desiredState: DesiredWindowState
    var restoreIntent: RestoreIntent?
    var managedReplacementMetadata: ManagedReplacementMetadata?
    var floatingState: FloatingState?
    var manualLayoutOverride: ManualWindowOverride?
    var ruleEffects: ManagedWindowRuleEffects
    var hiddenState: HiddenState?
    var layoutReason: LayoutReason
    // pid / windowId are derived from token
}
```

The focus session (`FocusSessionSnapshot`) and per-monitor visible-workspace state (`MonitorSession`) are value types defined in `Core/Reconcile/ReconcileSnapshot.swift` and held on `WorldStore`. There is no single `SessionState` type.

### 4.3 Niri Layout Engine (Orientation-Aware Scrolling Containers)

**Directory:** `Sources/OmniWM/Core/Layout/Niri/` (33 files)

Niri arranges containers along the monitor's primary axis, inspired by the [Niri](https://github.com/niri-wm/niri) Wayland compositor. In horizontal orientation, vertical columns scroll left and right and their windows stack vertically. In vertical orientation, horizontal rows scroll up and down and their windows span left to right.

```
NiriRoot (per workspace)
├── NiriContainer (column 1)
│   ├── NiriWindow (window A)
│   └── NiriWindow (window B)    ← stacked vertically
├── NiriContainer (column 2)
│   └── NiriWindow (window C)
└── NiriContainer (column 3)     ← can be tabbed
    ├── NiriWindow (window D)    ← active tab
    └── NiriWindow (window E)    ← hidden tab
```

| Type | Purpose |
|------|---------|
| `NiriLayoutEngine` | Owns per-workspace `NiriWorkspaceState` values with local roots and `nodesByToken` indexes, per-monitor `NiriMonitor` state, axis-solve cache, config. |
| `NiriRoot` | Per-workspace container; cached columns / all-windows / id set. |
| `NiriContainer` | A primary-axis container: `displayMode` (`.normal`/`.tabbed`), horizontal `width` state, vertical `height` state, `activeTileIdx`, and move/width springs. |
| `NiriWindow` | Leaf: `token`, `SizingMode` (`.normal`/`.maximized`/`.fullscreen`), horizontal-orientation `height`, vertical-orientation `windowWidth`, constraints, and move animations. |
| `ProportionalSize` | `.proportion(CGFloat)` or `.fixed(CGFloat)` — a container's primary span. |
| `WeightedSize` | `.auto(weight:)`, `.fixed(CGFloat)`, or `.preset(Int)` — a window's secondary span within its container. |
| `ViewportState` | Per-workspace scroll/selection snapshot. **Stored in `WorldStore.viewports`**, passed into `calculateLayout`. |

**Layout computation** lives in `NiriLayout.swift` (`calculateLayout(...) -> [WindowToken: CGRect]`). Monitor orientation selects the primary scroll axis and secondary window-distribution axis before frame calculation. **Constraint solving** is `NiriAxisSolver` in `NiriConstraintSolver.swift` — a pure 1-D solver distributing span across weighted windows while honoring min/max/fixed constraints, memoized in the engine's axis-solve cache.

**File organization.** The core engine is split across `NiriLayoutEngine.swift` plus twelve `NiriLayoutEngine+*.swift` extensions (`+Animation`, `+ColumnOps`, `+Monitors`, `+Sizing`, `+TabbedMode`, `+WindowOps`, `+Windows`, `+WorkspaceOps`, `+InteractiveMove`, `+InteractiveResize`, …), with navigation in `NiriNavigation.swift`, the node tree in `NiriNode.swift`, viewport math in `ViewportState.swift` (+4 extensions), and overlays for interactive move/resize, drag ghost, and swap targets. Tabbed Niri columns and grouped Dwindle tiles share the surface-layer `TabRailManager`.

**Interactive move/resize.** Desktop Niri moves resolve one configured non-Shift modifier chord at mouse-down. The chord defaults to Option: the base chord swaps windows, adding Shift selects insertion, and Off leaves modified drags entirely to applications. `DragGhostController` captures a ScreenCaptureKit thumbnail shown as a translucent ghost and `SwapTargetOverlay` highlights the drop target. Edge-dragging resizes the container on the primary axis and the selected window on the secondary axis. Each interaction captures its orientation at begin and keeps that axis ownership through update and completion.

### 4.4 Dwindle Layout Engine (BSP)

**Directory:** `Sources/OmniWM/Core/Layout/Dwindle/` (5 files)

Dwindle recursively divides screen space using binary splits, in the style of Hyprland's dwindle / bspwm.

```swift
final class DwindleNode {
    let id: DwindleNodeId            // UUID
    var kind: DwindleNodeKind
    var parent: DwindleNode?
    var children: [DwindleNode]      // 0 (leaf) or 2 (split)
    var cachedFrame, cachedContentFrame, cachedMinSize
    // CubicRectAnimation for smooth transitions
}

final class DwindleTile {
    let id: DwindleTileId             // stable tile/group identity
    private(set) var members: [DwindleTileMember]
    private(set) var activeIndex: Int
}

struct DwindleTileMember {
    var token: WindowToken
    var isFullscreen: Bool
}

enum DwindleNodeKind {
    case split(orientation: DwindleOrientation, ratio: CGFloat)
    case leaf(tile: DwindleTile?)
}
```

Each leaf owns one stable tile containing an ordered member list and one active member. Singleton-to-neighbor joins preserve the destination tile identity; extraction removes only the active member while preserving the remaining group identity and per-member fullscreen state. `DwindleLayoutEngine` owns these tree/tile mutations, while `DwindleLayoutHandler` owns hidden-member reveal, rollback, and verified focus completion. Group rails are derived through `WorldView` and applied by the shared `TabRailManager`; Overview projects the active member with a group-count badge.

`DwindleLayoutEngine.calculateLayout(for:screen:) -> [WindowToken: CGRect]`. **Smart split** (`planSplit`) chooses orientation from the available rectangle's slope vs. aspect; **preselection** lets the user direct where the next window inserts. The engine also supports resize/balance/whole-tile swap/toggle-orientation/toggle-fullscreen, grouped-member reorder, and geometric-neighbor navigation. Like Niri it is a plain `final class`, AX-free, mutation-gated by `WorldStore`.

### 4.5 Focus Lifecycle

Focus management is split across several objects (there is no single coordinator class — `KeyboardFocusLifecycleCoordinator.swift` now holds only value types: `KeyboardFocusTarget`, `ManagedFocusOrigin`, `ManagedFocusRequest`).

**The managed-focus loop** (see the full trace in [5.1](#51-focus-hotkey-flow)):

```
1. User presses focus-left.
2. CommandHandler resolves the target window in the engine.
3. WMController.focusWindow:
     a. intentLedger.beginManagedRequest(token, workspaceId, origin)
        → records a .focusWindow Intent + a 100ms settle deadline,
          so the upcoming AX echo classifies as echoOf (not external).
     b. workspaceManager.beginManagedFocusRequest
        → commits WMEvent.managedFocusRequested (records the request in the world).
4. WMController applies the effect selected from the merged request origin and live settings:
     - keyboard/programmatic and pointer-hover requests use the full
       activateApp + focusSpecificWindow + raiseWindow sequence;
     - focus-follows-mouse uses the focus-only applicator without an explicit
       public app activation or AX raise unless focus.raiseOnMouseFocus is enabled.
   The applicator then probes the focused window.
5. macOS emits an AX focused-window-changed echo → posted into EventIntake.
6. FactResolver gathers the focused-window fact off-main, re-enters the intake.
7. AXEventHandler.handleActivationFactsResolved:
     intentLedger.classifyFocusObservation(token) → .echoOf
     → treat as confirmation, not an unrelated external focus change.
8. workspaceManager.confirmManagedFocus commits .managedFocusConfirmed;
   intentLedger.confirmManagedRequest cancels the deadline.
```

| Type | Purpose |
|------|---------|
| `KeyboardFocusTarget` | Resolved focus: `token`, `axRef`, `workspaceId`, `isManaged`. |
| `ManagedFocusRequest` | In-flight request: `requestId`, `token`, `workspaceId`, `origin`, `phase` (`.awaitingSameAppActivation(sourceToken:isRetry:)`/`.awaitingConfirmation`), `retryCount`, `status` (`.pending`/`.confirmed`). |
| `EchoClassification` | `.echoOf` / `.lateEcho` / `.external` — see [3.7](#37-echo-classification--intents). |

Managed origins merge with `keyboardOrProgrammatic > pointerHover > focusFollowsMouse`; the request returned by `IntentLedger.beginManagedRequest` is authoritative, so a weaker hover cannot downgrade an existing request for the same target. Only `keyboardOrProgrammatic` confirmation may move the cursor into the focused window. Real Niri, Dwindle, deferred-Dwindle, and floating-window pointer focus use `focusFollowsMouse`; tab clicks and completed gestures retain `pointerHover` and therefore full fronting.

Focus-follows-mouse has two effects. The generated default is `focus.raiseOnMouseFocus = false`; in that mode OmniWM omits `NSRunningApplication.activate`, `kAXRaiseAction`, and explicit SkyLight ordering. The private specific-window primitive still establishes keyboard routing through `_SLPSSetFrontProcessWithOptions`, so focus without raise is a best-effort ordering contract: macOS or the client may activate or reorder itself. With `raiseOnMouseFocus = true`, OmniWM uses the existing full-fronting sequence. Both effects pass through the same hidden-app, lock-screen, and focus-policy gates.

Focus-only switching between key windows inside one application requires a staged private handoff. OmniWM deactivates the source key window, schedules the target activation phase on the existing `DeadlineWheel` after a fixed 40 ms internal gap, and begins the normal 100 ms confirmation interval only after that phase runs. A handoff started by a confirmation retry retains retry-origin fact verification after activation, while the 40 ms phase itself does not consume retry budget. The gap is neither a pointer dwell preference nor a blocking sleep. If focus-follows-mouse is disabled or the pointer target becomes stale during the gap, OmniWM restores the source only while the handoff still owns focus; an external, modal, or lock-screen takeover is abandoned without restoration to avoid stealing focus. Cancellation retires the deadline and pending world request. Disabling focus-follows-mouse cancels only when the merged origin remains exactly `focusFollowsMouse`, while a stronger merged origin continues.

`FocusPolicyEngine` (`Core/Reconcile/`) is a separate concern: time-bounded `FocusPolicyLease`s that suppress focus-follows-mouse during menus and app-switch transitions, scheduled on the same `DeadlineWheel`.

Native focus ownership and border projection are intentionally separate. `renderableFocusToken` remains managed-native-only for focus consumers and IPC. An exact external owner is stored as `ExternalFocusIdentity`; it may carry a `verifiedManagedParentToken` only after WindowServer confirms both the child's PID/WID and the parent's PID/WID. `borderFocusToken` projects that parent only while it is still the live `selectedManagedToken`. The child remains unmanaged and unsubscribed, selection is not rewritten, and PID-only, independent external, owned-surface, mismatched, or stale evidence produces no border.

### 4.6 Input Handling

**Hotkeys** (`Sources/OmniWM/Core/Input/`)

`ActionCatalog` is the source of truth for action metadata and shortcut assignability. `buildSpecs()` materializes **171** `ActionSpec`s (97 standalone actions + 2 scratchpad templates × 10 slots + 6 loop templates × 9), each with a title, search keywords, category, layout compatibility, default binding, and visibility. `HotkeyBinding`/`HotkeyBindingRegistry` persist exactly one binding per spec that is not `.unassignable`. `HotkeyBindingRegistry.resolve` matches the persisted list against the current defaults and rejects unknown, missing, or duplicate action IDs rather than repairing the file; each accepted trigger is still normalized through `canonicalizeTrigger`. Unassignable specs are never persisted but remain available to non-hotkey command surfaces such as IPC.

`HotkeyCenter` (`Hotkeys.swift`) installs one Carbon `InstallEventHandler` and registers each binding via `RegisterEventHotKey`, plus a virtual-hyper synthesis path. On a press it emits a `HotkeyInvocation` through `onCommand`; the invocation carries the semantic `HotkeyCommand` and optional `PhysicalHotkeyTrigger` metadata (`keyCode`, modifiers, and repeat state). `WMController` wires it to `eventIntake.enqueue(.hotkeyInvocation(invocation))`, so physical commands enter the same ordered intake pipeline as other world-mutating events and commands (falling back to `CommandHandler.handleHotkeyInvocation` only if intake is closed).

**Command routing** (`Core/Controller/CommandHandler.swift`). `handleHotkeyInvocation` gives `OverviewController` first refusal while Overview is open. The modal router uses physical keys for Escape, Enter, and non-repeating Command-W, recognizes the configured physical Overview toggle, and routes assigned structural commands against the selected Overview `WindowHandle`; recognized no-ops are consumed. Unsupported commands and triggerless external/IPC commands remain blocked. When Overview is inactive, `performCommand` enforces `isEnabled` and the **layout-compatibility guard**: a `.niri`-only command is ignored under Dwindle and vice versa (`.shared` commands work everywhere).

**Mouse events** (`Core/Controller/MouseEventHandler.swift`). A `CGEventTap` drives focus-follows-mouse through the existing 100 ms action-rate throttle and interactive move/resize, while raw multitouch frames (`MultitouchGestureSource`) drive trackpad swipes through one idle→armed→committed state machine with two routed modes: Niri viewport container scrolling on the active monitor's configured orientation axis and one-shot workspace switching (`TrackpadGestureIntent` resolves the mode from finger count and dominant axis; the switch fires through the same `switchWorkspaceRelative` seam as hotkeys, targeting the monitor under the cursor). The throttle is not a configurable hover delay and has no new trailing-edge scheduler. A committed viewport gesture retains its resolved axis for the rest of the gesture. Transient mouse events are coalesced *in the intake* before draining.

**SkyLight events** (`Core/SkyLight/CGSEventObserver.swift`). Registers for window-server notifications and posts them into the intake:

```swift
enum CGSWindowEvent {
    case created(windowId, spaceId)
    case destroyed(windowId, spaceId)
    case frameChanged(windowId)
    case closed(windowId)
    case frontAppChanged(pid)
    case orderChanged(windowId)
    case titleChanged(windowId)
}
```

Window create/move/front-app events originate here; AX *destroy/miniaturize/focused-window-changed* come from the per-app AX observers.

`AXEventHandler` is the sole owner of WindowServer movement subscriptions. The private subscription call replaces the complete set, so each update submits one sorted, deduplicated, nonempty array containing every managed entry, including hidden, parked, and native-fullscreen entries, plus exact prepared admissions. An identity revision forces resubmission across create, destroy, retirement, rekey, and prepared-admission transitions even when the WID set is unchanged. OmniWM retains the last successful set after a failure and retries on the next lifecycle transition. It deliberately does not make a count-zero call; when the desired set is empty, exact PID/WID and lifecycle checks reject stale events locally. External children are never added to this subscription set.

### 4.7 Window Rules Engine

**Directory:** `Sources/OmniWM/Core/Rules/` — `WindowRuleEngine.swift` plus the
`HiddenTitleBarRegistry` and `InputMethodBundleRegistry` structural lookup tables

`decision(for:token:appFullscreen:) -> WindowDecision` establishes structural ownership before it ranks rule
matches. User and built-in rules compile into separate `CompiledRule` lists; each list ranks matches by
specificity then declaration order, and an explicit user layout takes precedence over a built-in layout.
Evaluation proceeds through these boundaries:

1. `AXHelpTag` roles and input-method apps are hard external. `InputMethodBundleRegistry.discover()` seeds a
   known set of system text-input agents and then adds every `.app` bundle ID found in `/Library/Input Methods`,
   `/System/Library/Input Methods`, and `~/Library/Input Methods`, so third-party IMEs are covered too.
2. Failed AX attribute collection or missing role/subrole defers admission. When evaluation has a live
   `WindowToken`, the supplied WindowServer record must match both its window ID and PID; missing or mismatched
   evidence also defers.
3. A WindowServer record with a nonzero, non-self parent is hard external. No user or built-in rule can override
   that parent boundary.
4. A parentless root at or above the status-window level requires precise **user** inclusion. The matching rule
   must choose Tile or Float and specify both the exact AX role and AX subrole. Built-in rules cannot cross this
   high-level boundary.
5. Prohibited-app roots, buttonless accessory-app roots, non-`AXWindow` roles, and otherwise unsupported AX
   subroles require the same precise inclusion shape; either a user or built-in rule may supply it. A closeable
   accessory-app `AXWindow` with a standard root subrole at a lower level instead follows normal admission.
6. Standard and native-fullscreen root subroles are structurally eligible. `AXDialog` and `AXFloatingWindow`
   roots are also eligible when hidden-title-bar, window-chrome, main-window, or modal evidence proves an
   independent root. With none of those proofs, missing main/modal evidence defers; explicit negative evidence
   requires precise inclusion.
7. After those gates, matching rules, required-title deferral, native-fullscreen handling,
   `HiddenTitleBarRegistry`, and `AXWindowService.heuristicDisposition` determine Tile, Float, or deferral. The
   heuristic reads activation policy, subrole, and window-button evidence; size constraints are collected
   separately for layout and do not decide ownership.

```swift
struct WindowDecision: Equatable, Sendable {
    let disposition: WindowDecisionDisposition  // .managed/.floating/.unmanaged/.undecided
    let source: WindowDecisionSource            // .manualOverride/.userRule(UUID)/.builtInRule(String)/.heuristic
    let layoutDecisionKind: WindowDecisionLayoutKind   // .explicitLayout / .fallbackLayout
    let workspaceName: String?
    let ruleEffects: ManagedWindowRuleEffects   // minWidth/minHeight + matchedRuleId
    let admissionHints: ManagedWindowAdmissionHints    // initialNiriContainerPrimarySpan
    let heuristicReasons: [AXWindowHeuristicReason]
    let deferredReason: WindowDecisionDeferredReason?
}
```

The disposition is the ownership boundary, not a capability flag applied after tracking. `.unmanaged` decisions
contribute no rule effects or admission hints and never enter the authoritative `WindowModel`, layout engines,
Overview, managed-focus navigation, or become an auxiliary-surface target. An exactly verified external child may
retain the border on its already-selected managed parent, but the child itself remains unmanaged and no selection
is inferred or changed. The high-level user escape hatch bypasses only the level gate: exact WindowServer identity
and the parent, help-tag, and input-method exclusions still apply. Broad app/title rules and Automatic layout
cannot cross any precise-inclusion gate.

Per-app `initialContainerPrimarySpan` is an admission hint, not an ongoing `ManagedWindowRuleEffects` constraint.
`WindowRuleEngine` takes it only from the single winning rule, and Niri consumes it once when a resizable
window creates or claims a new container. Niri owns that initial primary-span seed before its normal fallback;
Dwindle ignores it, restored placement takes precedence, and later resize or relayout operations do not
reassert the rule value. Single Window Fit retains visual precedence for a lone window, while physical
minimum-size constraints can clamp the resolved span without mutating the stored initial proportion.

### 4.8 IPC System

For the protocol spec, current wire version, and CLI reference, see the [CLI & IPC reference](/reference/cli/overview/). This section covers the internal code architecture; `OmniWMIPCProtocol.version` in `Sources/OmniWMIPC/IPCModels.swift` is authoritative.

```
omniwmctl                         OmniWM process
─────────                         ──────────────
CLIParser                         IPCServer  (AF_UNIX accept loop on a DispatchQueue)
    │                                 │  getpeereid == geteuid
IPCClient ──── Unix socket ────► IPCConnection (actor, per client; NDJSON, 64 KiB/line)
  (NDJSON)                            │
                                 IPCApplicationBridge (actor)
                                      │ auth token + protocol version
                    ┌─────────────┬───┴────────┬───────────────┐
                    │             │            │               │
         commands/window/      capture      queries          rule ops
         workspace             control      (read projection) (add/replace/…)
                    │             │            │               │
  EventIntake.post(.ipcCommand)   │  @MainActor routers built fresh per request
                    v             v            v               v
            single-writer   WMController   IPCQueryRouter   IPCRuleRouter
            pipeline        trace capture  (live WM state)  (settings + reevaluate)
```

**Mutating commands enter the single-writer pipeline.** `IPCApplicationBridge` posts an `IPCCommandIntake` into `EventIntake` (`.ipcCommand`); the interpreter runs `intake.perform(controller)` on the main actor and completes the request. IPC commands do not mutate state directly — they flow through the same intake → world path as hotkeys.

**Capture control is a direct asynchronous bridge route.** It does not mutate window-manager world state, so start, stop, and status bypass `EventIntake` and call the same `WMController` trace-capture orchestration used by the UI. The shared coordinator remains the sole capture-state owner. Capture requests therefore remain available while window management is disabled, Overview is open, or the active layout differs, while retaining the standard IPC authorization and protocol checks.

**Actors and routers.** `IPCApplicationBridge`, `IPCConnection`, `IPCEventBroker`, and `IPCConnectionRegistry` are actors; the routers (`IPCCommandRouter`/`IPCQueryRouter`/`IPCRuleRouter`) and `IPCRuleProjection` are `@MainActor` and constructed fresh per request. `IPCEventBroker` holds per-channel `AsyncStream` continuations; `IPCEventDemandTracker` is an `NSLock`-guarded refcount so `hasSubscribers` can be checked nonisolated to skip producing events nobody wants. `IPCAutomationManifest` (in `OmniWMIPC`) is the shared declarative source of truth for commands/queries/channels.

**Security.** The trust boundary is the local user account. Each session carries an authorization token written newline-terminated at `<socket-path>.secret` with `0600` perms; the server enforces socket permissions `0600`, creates socket directories `0700`, and verifies the peer UID via `getpeereid()`.

### 4.9 Accessibility Layer

**Directory:** `Sources/OmniWM/Core/Ax/`

**Per-app threading.** `AXManager` keeps an `AppAXContext` per process. Each context spins a dedicated `NSThread`/`CFRunLoop` and performs all of that app's `AXUIElement` reads and writes there, plus its AX observers (window destroy/miniaturize + focused-window-changed). Per-thread state is pinned with `ThreadGuardedValue` against a `@TaskLocal appThreadToken`.

**Frame application.** `AXManager.applyFramesParallel` (still the live entry point — "parallel" refers to the per-app *thread* fan-out, not GCD) coalesces requests per pid and dispatches one `setFramesBatch` to each app's thread. The verification and retry bookkeeping lives in **`AXFrameApplicationLedger`**:

1. `prepareFrameApplication` dedups a target against the last-applied / pending frame within tolerance or the exact target of an accepted size convergence.
2. The write happens on the app thread via `AXWindowService.setFrame` (writes `kAXSize`/`kAXPosition` in order, then reads back to verify).
3. `handleFrameApplyResults` verifies observed vs. target; on mismatch it retries within a per-window budget (`retryBudgetByWindowId`, default 1) — re-enqueued synchronously by `AXManager`, scheduled via a per-window `Task { @MainActor }` generation counter, **not** the `DeadlineWheel`.
4. After the evidence retry, a repeated `verificationMismatch` is accepted only when both AX setters succeeded, both readbacks match, and the observed frame preserves the AX top-left position (`minX` and AppKit `maxY`) while differing solely by a bounded (≤16pt) app size snap. The ledger records the observed frame with that exact requested target, clears retry/failure state, and terminal observers receive normalized verified success. A different target always produces a new write; unstable readback, position drift, larger size deltas, and AX setter failures remain terminal refusals.
5. `FrameApplyTrace` records the raw AX result and the distinct `accepted-size-convergence` decision, keeping platform write evidence separate from ledger policy.

**Inactive-workspace suppression.** Windows on non-visible workspaces are tracked in `AXManager.inactiveWorkspaceWindowIds` (a `Set<Int>` rebuilt by `LayoutRefreshController`) and checked live before each write, avoiding pointless AX calls and visual glitches.

### 4.10 Spaces & Native Fullscreen

**Directory:** `Sources/OmniWM/Core/Spaces/`

OmniWM **requires** the macOS "Displays have separate Spaces" setting to be ON (`SkyLight.displaysHaveSeparateSpaces`, backed by `SLSGetSpaceManagementMode`); when it is OFF the window-management runtime does not start (the app stays alive with a status-bar warning), and an `unavailable` reading fails open so a missing private symbol never bricks tiling.

`SpaceTopology` is a pure value model of the macOS Spaces layout: per-display space lists + current space, the global active space (kept only as a frontmost-display hint), the set of fullscreen-type spaces, and a window→space map, with read-only derivations (`isCurrentSpace`, `isFullscreenSpace`, `isWindowOnKnownInactiveSpace`, `selectWindowSpace`, …). Because each display has its own active space, per-window space decisions use the **per-display current space** (`isCurrentSpace`) rather than the single global active space — e.g. `reconcileNativeFullscreenWithTopology` suspends a window whose fullscreen space is current **on its own display**. `SpaceTracker` is a `@MainActor` **stateless transform** that runs whenever services are active (it no longer gates the safety-critical refresh on `settings.spacesTrackingEnabled`): it rebuilds a fresh `SpaceTopology` from read-only SkyLight queries (`SLSCopyManagedDisplaySpaces`, `SLSCopySpacesForWindows`, selecting a window's desktop space via `SpaceTopology.selectWindowSpace`) and commits it through `WorldStore`. Refresh is driven by `NSWorkspace.activeSpaceDidChangeNotification` and `Notification.Name("NSWorkspaceActiveDisplayDidChangeNotification")`. The durable topology lives on `WorldStore` (`private(set) var spaceTopology`), not in the tracker.

**Native-inactive safety.** Windows on a known **inactive native Space** are left to macOS: they are frame-write-suppressed (even when their OmniWM workspace is active) and never physically parked off-screen, and a window created on an inactive native Space defers admission until its Space becomes current. The suppression self-heals — it clears on the next topology refresh once the Space is current, and no-ops when a window's Space is unknown.

**Native fullscreen** is now derived from facts, not inferred from AX element lifecycle:

- The old AX **destroy/recreate inference** (speculative-preserve heuristics, recreate-before-admission, timeout cleanup) was fully removed.
- The `NativeFullscreenAvailability` enum and the `isAppFullscreenActive` *stored boolean* were removed. `NativeFullscreenRecord` holds `originalToken`, `currentToken`, `workspaceId`, `transition`, and a transition generation used to reject stale deadlines.
- `WorkspaceManager.isAppFullscreenActive` is a **computed property** derived from the records: `nativeFullscreenRecordsByOriginalToken.values.contains { $0.transition == .suspended }`.

Native fullscreen is co-driven by two observed facts: (1) SkyLight fullscreen-space membership (`SpaceTracker.reconcileNativeFullscreenWithTopology`) and (2) the AX-observed `focusedWindow.isFullscreen` at activation (`AXEventHandler`). Topology/inventory suspension is focus-neutral; actual AX activation or placeholder selection sets the record's current token as the exact non-managed focus owner. Rekeys transfer that owner, restoring one record cannot clear another, and managed-focus confirmation or definitive owner removal clears it. Enter/exit requests use generation-checked, record-owned deadlines that are canceled on completion, removal, and service stop.

When management is suspended, `NativeFullscreenPlaceholderManager` retains one nonactivating, normal-level panel keyed by `record.originalToken`. The panel fills the accepted reserved tile with a black app-icon placeholder drawn by one Core Graphics/Core Text view. Translation-only ticks move the panel without rebuilding or redrawing content; accepted size changes resize the panel and redraw the cached icon/text presentation. Placeholders order out during inactive workspaces, fullscreen Spaces, transitions, invalid layout visibility, and temporary entry loss; they are destroyed only with the record or service. Activation resolves `record.currentToken` at action time. The panel is excluded from ScreenCaptureKit and the screenshot window picker. Capture diagnostics distinguish verified exclusion from an accepted write whose private-API readback is unavailable, and high-frequency geometry events use a separate bounded motion trace so they cannot evict lifecycle evidence.

### 4.11 Surface System

**Directories:** `Sources/OmniWM/Core/Surface/`, `Sources/OmniWM/Core/Border/`

`WorldView` is a read-only `@MainActor` facade wrapping a single `WMController`. It exposes exactly the state `SurfaceDerivation` needs (managed-only renderable focus, border focus projection, scoped fullscreen-transition queries, monitors, space topology, border config, per-window observed/pending frames) plus helpers that build tab-rail infos, bar surfaces, and native-fullscreen descriptors. It holds no mutable state and is constructed fresh per reconcile pass.

`SurfaceDerivation.derive(world:)` is a pure transform `WorldView → DesiredSurfaceScene`. The border-eligibility gate in `deriveBorder` starts from `borderFocusToken`, resolves that projection back to a live managed entry, and retains the existing visibility, suppression, system-modal, layout-fullscreen, and native-fullscreen-transition checks. Unrelated fullscreen records no longer suppress borders or focus recovery on other workspaces.

**The focus border** is no longer an `NSWindow` managed by a dedicated controller. It is a derived surface applied by `BorderSurfaceApplier`, which drives one persistent private **SkyLight/CGS server-side window** created through `SkyLight.createBorderWindow` and drawn into a `CGContext`. `BorderWindow` queries the target through the existing WindowServer iterator, accepts the level only when both PID and WID match, and orders the border at that level with `transactionMoveAndOrder(.below)`. A transient lookup failure may reuse only the same target token's cached level; otherwise it falls back to level 0 and schedules one later border-only retry. Translation-only updates move the existing surface without a level or scale query, reshape, or redraw.

The target frame is rounded once to physical pixels and the server surface expands outward by the configured width. Drawing uses an even-odd clip with a transparent rounded target cutout and an outer radius equal to the sampled target radius plus the border width, so no border pixel intentionally enters the target silhouette. `targetFrameOnScreen` records the rounded target while `frameOnScreen` reports the expanded surface. The surface remains registered with `SurfaceCoordinator` by CGS window number and opts out of the screenshot window picker through `IgnoreForScreencaptureWindowSelection`; that property is invisible to full-screen captures and screen recording.

**`SurfaceCoordinator`** (a `.shared` singleton) is the registry of OmniWM-owned surfaces, backed by `SurfaceScene`. Beyond "exclude from tiling" it answers hit-testing (`containsInteractive`), ScreenCaptureKit capture-eligibility (`isCaptureEligible`), and focus-recovery suppression (`hasFrontmostSuppressingWindow`). The vocabulary lives in `SurfaceScene.swift`: `SurfaceKind` (`border`, `parkingEdgeMask`, `workspaceBar`, `overview`, `nativeFullscreenPlaceholder`, `tabRail`, `dragGhost`, `utility`, `quake`, `launchOverlay`, `secureInputIndicator`, `systemStats`, `hiddenBarPanel`), `HitTestPolicy`, `CapturePolicy`, and `SurfacePolicy` (which bundles them plus `suppressesManagedFocusRecovery`). `OwnedWindowRegistry` (in `App/`) is now a thin facade over `SurfaceCoordinator.shared`.

### 4.12 Animation System

**Directory:** `Sources/OmniWM/Core/Animation/`

- **`SpringAnimation` / `SpringConfig`** — a closed-form damped-spring solver sampled by absolute `CACurrentMediaTime`. `offsetBy(_:)` rebases both endpoints so the world can re-anchor a viewport mid-flight. The named presets (`niriHorizontalViewMovement`, `niriWindowMovement`, `niriWindowResize`, and the `snappy`/`balanced`/`default` aliases) all use the same critically-damped curve (`dampingRatio 1.0`, `stiffness 800`).
- **`CubicAnimation`** — cubic-bezier easing used by the Dwindle path.
- **`MoveAnimation`** — a spring plus a starting offset, used by the Niri engine for per-window/column motion.
- **`DecelerationAnimation`** — exponential-decay inertia (`decelerationRate 0.997`) for thrown viewport gestures.
- **`AnimationDriver`** — owns the per-workspace **viewport scroll motion only**. Its `ViewportMotion` enum covers `gesture` (live `SwipeTracker`), `spring`, and `deceleration` (inertial throw), and it can seed or rebase either animation type. It is seeded from inside the commit path (`reconcileViewportCommit` re-seeds the spring from a committed `ViewportState` transition) and sampled per frame by `NiriLayoutHandler`. Per-window/column animations live in the Niri engine, not here.
- **`SwipeTracker`** — accumulates trackpad deltas over an 80 ms history window and reports the release velocity that seeds the throw animation.
- **`AnimationClock`** — a monotonic accumulating clock over `CACurrentMediaTime`, held by the engines and `WMController`.
- **`MotionPolicy`** — a `@MainActor @Observable` single boolean (`animationsEnabled`) seeded from settings; it gates OmniWM-authored animations.
- **Native-fullscreen placeholder panels** — consume the same accepted Niri rendered frames or Dwindle interpolated frames as managed windows. Translation-only animation performs an origin move; actual tile-size animation resizes the full-tile panel while reusing cached app identity and Core Text lines.

The per-frame **display link** is owned by `LayoutRefreshController` (not by `Animation/`); see [3.9](#39-the-ungated-animation-tier).

### 4.13 Clipboard History

**Directory:** `Sources/OmniWM/Core/Clipboard/`

`ClipboardHistoryService` polls `NSPasteboard.changeCount` every 0.5s, captures changed contents off-main through a pasteboard reader (filtering out 1Password/transient/concealed types), and feeds them to `ClipboardHistoryStore` — a Swift **actor** that deduplicates by SHA-256 digest, maintains MRU ordering, prunes by item/byte limits, and atomically persists to `clipboard-history.json` (`0600`). History is surfaced as the **clipboard mode** of the Command Palette; `WMController` exposes `clipboardPaletteItems()` / `copyClipboardItem(id:)` / `deleteClipboardItem(id:)` / `clearClipboardHistory()`.

### 4.14 Additional Features

| Feature | Key Files | Description |
|---------|-----------|-------------|
| **Overview** | `Core/Overview/OverviewController.swift` | Expose-style workspace overview. Rendered with **Core Graphics** (`OverviewView.draw → OverviewRenderer.render(context: CGContext)`), not Metal; thumbnails via ScreenCaptureKit (`SCScreenshotManager`, ≤4 concurrent). Search, structural hotkeys, and Option-drag placement. |
| **Quake Terminal** | `QuakeTerminal/QuakeTerminalController.swift` | Drop-down terminal on GhosttyKit. Each tab is a tree of split panes (`QuakeTerminalTab` → `QuakeSplitContainer`/`SplitNode`), each a `GhosttySurfaceView` (CAMetalLayer-backed). Slide-in/out animation; registers as a `.quake` surface. |
| **Command Palette** | `UI/CommandPalette/CommandPaletteController.swift` | Fuzzy search over windows, application menus, and clipboard history. |
| **Menu Anywhere** | `UI/MenuAnywhere/MenuAnywhereController.swift` | Pops the frontmost app's menu bar as a native `NSMenu` at the cursor, via `MenuExtractor` (ObjC runtime AX-tree walk). |
| **Workspace Bar** | `UI/WorkspaceBar/WorkspaceBarManager.swift` | Per-monitor workspace bars — now **driven by `SurfaceReconciler`** via `apply([DesiredBarSurface])`, not self-polling. |
| **Hidden Bar** | `UI/HiddenBar/HiddenBarController.swift` | Per-app menu-bar concealment coordinated through an isolated assessment-mode assertion, AX item discovery and icon capture, and a hidden-items panel. Concealment hides OmniWM's native status item and shows one fallback icon per display, beside a visible workspace bar or near the display's top center; bundled and unbundled launches behave the same. |
| **Status Bar** | `UI/StatusBar/StatusBarController.swift` | Menu-bar icon, settings access, manual update checks. |
| **Scratchpad** | `Core/Workspace/WorkspaceManager.swift` | Ten slots of floating windows (`scratchpadMembers` / `revealedScratchpad` on `WorldStore`); at most one slot revealed, show/hide coordinated by `WMController`. |
| **Monitors** | `Core/Monitor/` | Display detection (`Monitor.current()`), UUID-first durable identity (`OutputId`), and `resolveWorkspaceRestoreAssignments` in `MonitorRestoreAssignments.swift` (re-maps saved per-monitor workspaces by unique display UUID, then uses runtime ID/name only for UUID-less displays before geometry/name best-match; `MonitorRestoreKey` is the data-only identity it matches on). Duplicate live UUID claims fail closed to session-only runtime identity. Orientation reported over IPC is the **effective** orientation (`settings.effectiveOrientation` — override or auto). |
| **Sleep / Lock** | `Core/Sleep/`, `Core/LockScreen/` | `SleepPreventionManager` (IOPM assertion), `LockScreenObserver` (DistributedNotificationCenter lock/unlock). |
| **System Stats** | `UI/SystemStats/SystemStatsSampler.swift` | CPU, memory-pressure, GPU, disk, and uptime sampling behind an optional workspace-bar button and popup; registers as a `.systemStats` surface. |
| **Diagnostics & Trace Capture** | `Core/Diagnostics/RuntimeTraceCaptureCoordinator.swift` | Bounded ring recorders per domain plus the single capture owner for the `problem` (wire name `trace`) and `performance` profiles. Both auto-finalize after 600s; the UI, the status bar, and IPC all drive the same coordinator. |
| **Issue Reporter** | `Core/IssueReporter/FoundationModelsIssueEngine.swift` | Optionally rewrites a rough bug report into the five-section issue template on Apple's on-device model, then builds a pre-filled GitHub URL (`maxURLLength` 8000). Without an applied rewrite, the manual form uses deterministic formatting; rewrite failures report an error and leave that draft available. Prompts live as Markdown resources — see [issue-report-prompt.md](https://github.com/BarutSRB/OmniWM/blob/main/docs/issue-report-prompt.md). |
| **Release Updater** | `App/UpdateCoordinator.swift` | Polls the latest GitHub release once per day, supports manual checks, shows a release-notes popup. |

**Overview mutation ownership.** `NiriLayoutHandler` owns explicit-`WindowHandle` Niri reorder, consume/expel, column, and insertion mutations; `WorkspaceNavigationHandler` owns explicit-handle window workspace/monitor transfers and Niri whole-column workspace transfers. Their internal `StructuralMutationOutcome` reports the selected handle, moved tokens, destination, and affected workspaces. `OverviewController` uses that result to make `WorkspaceManager` activate the destination workspace and interaction monitor, commit remembered layout focus, request relayout only for affected workspaces, and keep the moved window selected. Overview mutations suppress client-window activation, so no AX focus is issued until an intentional dismissal focuses the current selection.

Option-drag continues to resolve an `OverviewDragTarget` for workspace-only, exact-card, or between-column placement. A cross-layout move into Niri first commits destination admission, then applies the exact target in a version-gated post-layout continuation; if the continuation is invalidated, the workspace transfer remains authoritative and the stale insertion is discarded. Projection refreshes reuse cached titles, frames, icons, and thumbnails while updating affected engine snapshots and active-workspace flags. Close completion is driven by `WorkspaceManager.onWindowRemoved`, not a speculative timer, so selection advances only after authoritative removal.

---

## 5. Data Flow Diagrams

### 5.1 Focus Hotkey Flow

User presses a focus hotkey (e.g. focus-left). Note how the `IntentLedger` makes the resulting AX echo classifiable as our own action:

```
HotkeyCenter.dispatch → onCommand(HotkeyInvocation)       [INTAKE transport]
    │  command + optional PhysicalHotkeyTrigger(keyCode, modifiers, isRepeat)
    v
EventIntake.enqueue(.hotkeyInvocation) → drain            [STAGE 1]
    │  CFRunLoopPerformBlock on main
    v
EventInterpreter.handleIntakeEvent → CommandHandler.handleHotkeyInvocation
    │
    ├── Overview open: OverviewController modal routing            [TERMINAL]
    │      selected-card navigation/mutation or consumed/blocked command;
    │      no client AX focus until intentional dismissal
    │
    └── Overview inactive
           │
           v
        CommandHandler.performCommand
           │
           v
        executeCombinedNavigation → WMController.focusWindow
           │  resolves the target NiriNode
           ├──> IntentLedger.beginManagedRequest(token)   records .focusWindow Intent
           │       + DeadlineWheel 100ms settle deadline   (so the echo = echoOf)
           └──> WorkspaceManager.beginManagedFocusRequest
                   v
               WorldStore.commit(.managedFocusRequested)  [STAGE 2] seq++
    │
    v
WMController.performWindowFronting                        [STAGE 3 — effector]
    │  activateApp + focusSpecificWindow + raiseWindow (private APIs)
    v
macOS emits AX focused-window-changed echo
    │  AppAXContext observer → EventIntake.post(.axFocusedWindowChanged)
    v
EventInterpreter → AXEventHandler.handleAppActivation     [STAGE 1 re-entry]
    │  FactResolver.resolveActivationFacts (off-main) → EventIntake.post(.activationFactsResolved)
    v
AXEventHandler.handleActivationFactsResolved
    │  IntentLedger.classifyFocusObservation → .echoOf  (confirmation, not external)
    v
WorkspaceManager.confirmManagedFocus → WorldStore.commit(.managedFocusConfirmed)  seq++
    │  IntentLedger.confirmManagedRequest cancels the deadline
    v
WMController.handleSessionStateChanged → SurfaceReconciler.noteWorldChanged   [STAGE 4]
    │  SurfaceDerivation.deriveBorder reads WorldView.borderFocusToken
    v
BorderSurfaceApplier moves the focus border to the newly focused window
```

### 5.2 External Window Event Flow

An application opens a new window:

```
macOS window server creates window
    │
    v
CGSEventObserver.handleRawCGSEvent → EventIntake.post(.cgs(.created))   [INTAKE]
    │  CGSEventObserver.swift:120
    v
EventIntake stamps seq + schedules one drain (CFRunLoopPerformBlock)    [STAGE 1]
    v
EventInterpreter → AXEventHandler.handleCGSEvent → handleCGSWindowCreated
    │  → processCreatedWindow → trackPreparedCreate (reads AX attrs, runs rules)
    v
WindowRuleEngine.decision(for:token:appFullscreen:) → .managed / .floating / .unmanaged
    v
WorkspaceManager.addWindow → recordReconcileEvent(.windowAdmitted)      [STAGE 2]
    │  WorldStore.commit: seq++, model.upsert, EventNormalizer,
    │  StateReducer.reduce → ActionPlan, InvariantChecks, ReconcileTxn
    v
AXEventHandler → LayoutRefreshController.requestRelayout(.axWindowCreated)  [STAGE 3]
    │  buildRelayoutEffectPlan (inside a withBatchedLayoutBuild commit) → EffectPlan
    v
LayoutRefreshController.executeEffectPlan → AXManager.applyFramesParallel
    │  per-pid batch → AppAXContext.setFramesBatch on the app's AX thread
    │  AXFrameApplicationLedger verifies / retries / settles exact convergence
    v
SurfaceReconciler.noteWorldChanged → WorldView → desired surface scene diff-applied [STAGE 4]
```

### 5.3 IPC Command Flow

User runs `omniwmctl command focus left`:

```
CLIParser.parse → IPCRequest { kind: .command, payload: focus(left) }
    v
IPCClient connects to the Unix socket, sends NDJSON
    v
IPCServer accepts → IPCConnection (actor) reads the NDJSON line
    v
IPCConnection: decode version envelope → version gate → full IPCRequest
    v
IPCApplicationBridge (actor): verify token + protocol version
    │  for mutating commands: EventIntake.post(.ipcCommand(intake))
    v
EventInterpreter (.ipcCommand) → intake.perform(controller)             [STAGE 1]
    │  → CommandHandler.performCommand(.focus(.left))
    │      (same semantic path as the inactive-Overview branch in 5.1;
    │       returns .ignoredOverview while Overview is open)
    v
ExternalCommandResult → IPCResponse { ok: true } → NDJSON → client
    v
CLIRenderer displays the result
```

---

## 6. Common Contribution Patterns

### 6.1 Adding a New Hotkey Command

1. **Add the enum case** in `Core/Input/HotkeyCommand.swift`.
2. **Add the action spec** in `Core/Input/ActionCatalog.swift` (title, keywords, category, layout compatibility, default binding, and visibility). This is the source of truth for command metadata and shortcut assignability; `.unassignable` specs are omitted from default bindings while retaining metadata for non-hotkey command surfaces.
3. **Handle it** in `Core/Controller/CommandHandler.swift` — set the right `LayoutCompatibility` so the guard accepts it under the active layout. Mutations must reach the world through `WorkspaceManager.recordReconcileEvent`, never by touching `WindowModel`/engines directly.
4. **Route structural Overview behavior** when applicable in `OverviewController`, using an explicit-`WindowHandle` entry point owned by `NiriLayoutHandler` or `WorkspaceNavigationHandler`; do not fall back to the desktop-focused window.
5. **Expose via IPC** (optional) in `IPC/IPCCommandRouter.swift` and the manifest (`OmniWMIPC/IPCAutomationManifest.swift`); add the CLI name in `OmniWMCtl/CLIParser.swift`.

### 6.2 Adding a New IPC Query

1. Define the response model in `OmniWMIPC/IPCModels.swift`.
2. Implement the read-only projection in `IPC/IPCQueryRouter.swift` from live `WMController`/`WorkspaceManager` state.
3. Add CLI rendering/parsing in `OmniWMCtl/`, and the descriptor in `IPCAutomationManifest.swift`.

### 6.3 Adding a New Setting

1. Add the property to `Core/Config/SettingsStore.swift` (give it a `didSet` that calls `scheduleSave()` if it should persist).
2. Wire runtime behavior in `WMController.applyPersistedSettings()` or the consuming handler.
3. Add UI under `Sources/OmniWM/UI/`.
4. Thread it through the TOML model: `SettingsExport.swift`, `CanonicalTOMLConfig.swift`, `SettingsTOMLCodec.swift`. `settings.toml` is the only settings source of truth — verify it survives encode/decode. Operational/runtime state (updater status, restore catalog, palette mode, Quake custom frame, issue draft/walkthrough, and monitor-setup status) belongs in `RuntimeStateStore` (`runtime-state.json`), not the TOML.

### 6.4 Modifying Layout Behavior

1. Pick the engine: `Core/Layout/Niri/` or `Core/Layout/Dwindle/`.
2. For Niri, find the right `NiriLayoutEngine+*.swift` extension (`+ColumnOps`, `+Sizing`, `+TabbedMode`, `+WindowOps`, `+WorkspaceOps`, `+Animation`, …); navigation is in `NiriNavigation.swift`, constraint solving in `NiriConstraintSolver.swift`.
3. Keep engines pure: no AX calls, no frame writes. Any engine mutation must run inside a commit — enter one via `withEngineMutationScope` (or `withBatchedLayoutBuild` for plan-building); the engines assert otherwise. Emit a frame map; let `NiriLayoutHandler`/`DwindleLayoutHandler` build the `EffectPlan`.

### 6.5 Working with Private APIs

1. `@_silgen_name` declarations live in `Core/PrivateAPIs.swift`; runtime `dlopen`/`dlsym` wrappers in `Core/SkyLight/SkyLight.swift`.
2. Wrap every private call in a safe Swift function with a fallback. Private APIs can break across macOS versions — verify behavior across versions and prefer public APIs where possible.

---

## 7. Glossary

| Term | Definition |
|------|-----------|
| `EventIntake` | The single ordered buffer for transports participating in the semantic world-state pipeline; monotonic global `seq`; one main-run-loop drain per cycle. Read-only IPC and capture control bypass it. |
| `EventInterpreter` | The drain sink — a pure switch that dispatches each `IntakeEvent` to a `WMController` sub-handler. Does not classify or commit. |
| `FactResolver` | Gathers activation-focus and deferred window-constraint facts on an app AX thread or shared resolver thread, then re-enters intake via `.activationFactsResolved` or `.windowConstraintsResolved`. |
| `IntentLedger` | Ring buffer of focus/activation `Intent`s; `classifyFocusObservation` returns `echoOf`/`lateEcho`/`external`. |
| `DeadlineWheel` | Main-actor timing wheel; posts `.intentExpired` back into the intake. Drives intent settle/expiry, not frame retries. |
| `WMEvent` | The typed, exhaustive event consumed by `WorldStore.commit`. |
| `WorldStore` | The single synchronous writer. Owns `WindowModel`, focus, viewports, monitor sessions, PID-scoped app visibility and generations, space topology, and both engines (all private). |
| `commit` | `WorldStore.commit(_:…)` — normalize → reduce → resolve → invariants; bumps `seq`. The semantic model/focus/workspace/engine mutation path; invalidation bookkeeping and the animation tier are explicit exceptions. |
| `withEngineMutationScope` | `WorkspaceManager` wrapper that runs an engine mutation inside its own `commit`; `withBatchedLayoutBuild` is the plan-building variant. |
| `ActionPlan` | Pure output of `StateReducer.reduce` — per-domain state deltas + a `ViewportPlan` + notes. |
| `EffectPlan` | Effector-side plan (`Core/Layout/LayoutBoundary.swift`): per-workspace layout diffs + seq-gated post-layout actions. Built by the layout handlers. |
| `InvalidationMarks` | Per-domain `seq` watermarks used to drop layout plans that were built against a now-stale world. |
| `InvariantChecks` | Post-commit consistency checks. Every returned violation is traced and triggers `assertionFailure` in Debug builds; there is no severity split. |
| `WindowToken` | Value type (`pid` + `windowId`). Primary dictionary key; survives AX recreation via rekey. |
| `WindowHandle` | Reference-identity wrapper around a `WindowToken`; re-pointed on rekey. |
| `AXWindowRef` | Accessibility bridge (`AXUIElement` + `windowId`); equality by `windowId`. |
| `WindowState` | Per-window value record stored in `WindowModel` (replaces the old `WindowModel.Entry`). |
| `WindowModel` | Reference-type per-window registry, now **private to `WorldStore`**. |
| `FocusSessionSnapshot` | Value type holding focused token, pending managed focus, per-workspace last-focused, lease, etc. (on `WorldStore.focus`). |
| `MonitorSession` | Per-monitor visible/previous workspace (on `WorldStore.monitorSessions`). |
| `ViewportState` | Niri per-workspace scroll/selection state, stored in `WorldStore.viewports`. |
| `LayoutRefreshController` | The effector: schedules refreshes, runs the display-link loop, executes `EffectPlan`s. |
| `RefreshReason` / `RefreshRequestRoute` | Why a refresh was requested, and which route it maps to (`fullRescan`/`relayout`/`immediateRelayout`/`visibilityRefresh`/`windowRemoval`). |
| `AXManager` | Per-app AX frame writer; owns `AXFrameApplicationLedger`. `applyFramesParallel` = per-app thread fan-out. |
| `AXFrameApplicationLedger` | Dedups, verifies, retries, and records exact accepted size convergence for frame writes. |
| `SurfaceReconciler` | Stage 4: derives border, bars, tab rails, native-fullscreen placeholders, and parking-edge masks from `WorldView` and diff-applies them. |
| `WorldView` | Read-only facade over world state used by `SurfaceDerivation`. |
| `SurfaceCoordinator` / `SurfaceScene` | Registry + policy store for OmniWM-owned surfaces (hit-testing, capture exclusion, focus-recovery suppression). |
| `SpaceTopology` | Pure value model of the macOS Spaces layout (per-display spaces, current/fullscreen spaces, window→space map). |
| `SpaceTracker` | Stateless transform that rebuilds `SpaceTopology` from read-only SkyLight queries and commits it. |
| `NativeFullscreenRecord` | Per-window record (`originalToken`, `currentToken`, `workspaceId`, `transition`, `transitionGeneration`) from which lifecycle, exact focus ownership, and deadlines are derived. |
| `AnimationDriver` | Owns per-workspace viewport scroll motion (gesture, spring, or deceleration). |
| `SpringConfig` | Spring parameters; presets are all the same critically-damped curve. |
| `MotionPolicy` | Settings-backed gate for OmniWM-authored animations. |
| `HotkeyCommand` | Semantic command enum shared by hotkey invocations and selected IPC routes. Catalogued cases receive binding, visibility, title, and compatibility metadata from `ActionCatalog`; IPC-only cases can be uncatalogued (such as `swapWorkspaceWithMonitor`) or use other request types. |
| `WindowDecision` | Rule-evaluation result: `disposition`, `source`, `layoutDecisionKind`, `workspaceName`, `ruleEffects`, `admissionHints`, `heuristicReasons`, and `deferredReason`. |

---

## 8. Design Decisions & Terminology Changes

### Single source of truth, by design

The redesign's north star is one authoritative world with one writer. Several otherwise-reasonable refactors were **deliberately not pursued** because they would distribute truth or mutation across more objects, working against that goal:

- **Ledger fold (not pursued).** Folding `IntentLedger` (focus/activation intents) and `AXFrameApplicationLedger` (frame-write verification) into one type was considered and rejected. They are two clean, non-overlapping truths on different stages of the pipeline; merging them would add coupling with no single-source-of-truth benefit.
- **God-file dissolution (not pursued).** `WMController`, `WorkspaceManager`, `LayoutRefreshController`, and `AXEventHandler` are large, but their size comes from *logic*, not from duplicated state — the world is already centralized in `WorldStore`. Mechanically extracting sub-objects would scatter state and mutation across more coordinating objects, i.e. move *away* from the single-writer model. Size alone is not a reason to split here.
- **"Everything through commit" (plan-build landed; animation tier deferred).** Layout plan-build now mutates the engines inside `commit`: `buildRelayoutEffectPlan` runs under `withBatchedLayoutBuild`, a single synchronous `layout_build` commit. The 60–120Hz animation tier still mutates engine/viewport offsets outside `commit` entirely (see [3.9](#39-the-ungated-animation-tier)); it must stay ungated for responsiveness, so gating it is deferred and scoped on its own, not bundled here.

### Terminology changes since the previous architecture

Long-standing names that a returning contributor may search for, and what replaced them:

| Removed / renamed | Now |
|-------------------|-----|
| `RuntimeStore` / `RuntimeStore.transact` | `WorldStore.commit` (`Core/World/`), entered via `WorkspaceManager.recordReconcileEvent` |
| `SessionState` (single type) | Split into `FocusSessionSnapshot`, `MonitorSession`, `viewports`, `scratchpadMembers` on `WorldStore` |
| `WindowModel.Entry` (nested struct) | `WindowState` (top-level value type) |
| `BorderManager` / `FocusBorderController` / `BorderCoordinator` | Derived surface: `SurfaceReconciler` → `BorderSurfaceApplier` → `BorderWindow` |
| `FocusBridgeCoordinator` | Managed focus split across `WMController`, `AXEventHandler`, `WorkspaceManager`, `IntentLedger` |
| `isAppFullscreenActive` (stored flag) | Derived from `NativeFullscreenRecord`s |
| AX destroy/recreate native-fullscreen inference | Topology (`SpaceTracker`) + AX-observed fullscreen at activation |

`KeyboardFocusLifecycleCoordinator.swift` still exists but now holds only value types (`KeyboardFocusTarget`, `ManagedFocusOrigin`, `ManagedFocusRequest`); it is not a coordinator class. `WindowModel`, `AXManager`, and `ReconcileTraceRecorder` were *not* removed — `WindowModel` is now private to `WorldStore`, and `AXManager` remains the per-app frame writer.
