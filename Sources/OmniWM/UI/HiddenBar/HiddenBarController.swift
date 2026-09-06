// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit

struct HiddenBarActivationOwner: Equatable, Sendable {
    let pid: pid_t
    let allowsAuthoritativeEmpty: Bool
}

@MainActor
final class HiddenBarController {
    private enum ObserverEvent: Sendable {
        case didBecomeActive
        case runningApplicationChanged(bundleID: String?, terminated: Bool)
        case applicationActivated
        case screenParametersChanged
    }

    enum MenuGuardTerminalReason: Equatable, Sendable {
        case concealed
        case noRevealedItems
        case unknownStateLimit
        case watchdog
        case cancelled
        case superseded
    }

    struct PerformanceSnapshot: Equatable, Sendable {
        let refreshEvents: UInt64
        let menuGuardQueries: UInt64
        let reconcealTasksStarted: UInt64
        let reconcealTasksCancelled: UInt64
        let menuGuardDeferrals: UInt64
        let maximumConsecutiveDeferrals: Int
        let terminalReason: MenuGuardTerminalReason?
    }

    private struct PerformanceCounters {
        var refreshEvents: UInt64 = 0
        var menuGuardQueries: UInt64 = 0
        var reconcealTasksStarted: UInt64 = 0
        var reconcealTasksCancelled: UInt64 = 0
        var menuGuardDeferrals: UInt64 = 0
        var maximumConsecutiveDeferrals = 0
        var terminalReason: MenuGuardTerminalReason?

        var snapshot: PerformanceSnapshot {
            PerformanceSnapshot(
                refreshEvents: refreshEvents,
                menuGuardQueries: menuGuardQueries,
                reconcealTasksStarted: reconcealTasksStarted,
                reconcealTasksCancelled: reconcealTasksCancelled,
                menuGuardDeferrals: menuGuardDeferrals,
                maximumConsecutiveDeferrals: maximumConsecutiveDeferrals,
                terminalReason: terminalReason
            )
        }
    }

    private struct ActiveActivation: Equatable {
        let bundleID: String
        let pid: pid_t
        let generation: Int
    }

    private let settings: SettingsStore
    private let hider = AssessmentModeHider()
    private let itemService: MenuBarItemService
    private let panel = HiddenBarPanelController()
    private let iconCache = HiddenBarIconCache()
    private let forwarder: HiddenBarClickForwarder
    private let fallbackIcon = HiddenBarFallbackIconController()

    var onFallbackIconClick: ((NSEvent, NSView) -> Void)?
    var fallbackPlacementsProvider: (() -> [HiddenBarFallbackIconPlacement])?
    var menuGuardSleeper: @MainActor (Duration) async throws -> Void = {
        try await Task.sleep(for: $0)
    }

    var menuGuardNow: @MainActor () -> ContinuousClock.Instant = { ContinuousClock().now }
    var menuOpenProviderForTests: (@MainActor (Set<pid_t>) async -> Bool?)?
    var topologyRefreshSleeper: @MainActor (Duration) async throws -> Void = {
        try await Task.sleep(for: $0)
    }

    var onTopologyRefreshForTests: (() -> Void)?

    private var reconcealTask: Task<Void, Never>?
    private var reconcealGeneration = 0
    private var activationTask: Task<Void, Never>?
    private var activationGeneration = 0
    private var activeActivation: ActiveActivation?
    private var captureTask: Task<Void, Never>?
    private var captureBundleIDs: Set<String> = []
    private var captureGeneration = 0
    private var temporarilyRevealed: Set<String> = []
    private var didBecomeActiveObserver: NSObjectProtocol?
    private var appLaunchObserver: NSObjectProtocol?
    private var appTerminationObserver: NSObjectProtocol?
    private var appActivationObserver: NSObjectProtocol?
    private var screenParametersObserver: NSObjectProtocol?
    private var topologyRefreshTask: Task<Void, Never>?
    private var topologyRefreshGeneration = 0
    private var observerGeneration = 0
    private weak var omniButton: NSStatusBarButton?
    private weak var omniStatusItem: NSStatusItem?
    private var performanceCounters: PerformanceCounters?

    private nonisolated static let menuGuardRetryDelays: [Duration] = [
        .milliseconds(250),
        .milliseconds(500),
        .seconds(1),
        .seconds(2)
    ]
    private nonisolated static let maximumConsecutiveUnknownMenuStates = 3
    private nonisolated static let menuGuardWatchdogDuration: Duration = .seconds(60)
    private static let captureDeadline: Duration = .milliseconds(500)
    private static let topologyRefreshDelay: Duration = .milliseconds(150)

    init(settings: SettingsStore) {
        self.settings = settings
        let itemService = MenuBarItemService()
        self.itemService = itemService
        forwarder = HiddenBarClickForwarder(itemService: itemService)
        panel.onActivate = { [weak self] key in
            self?.activateHiddenItem(key)
        }
        iconCache.onChange = { [weak self] in
            self?.refreshPanelIfVisible()
        }
        hider.onConcealingChanged = { [weak self] concealing in
            self?.handleConcealingChanged(concealing)
        }
        fallbackIcon.onClick = { [weak self] event, anchor in
            self?.onFallbackIconClick?(event, anchor)
        }
        panel.isExemptWindow = { [weak self] window in
            self?.ownsStatusItemWindow(window) == true
        }
    }

    func ownsStatusItemWindow(_ window: NSWindow) -> Bool {
        window === omniButton?.window || fallbackIcon.owns(window: window)
    }

    var isHidingAvailable: Bool {
        hider.available
    }

    var onCursorWarp: ((CGPoint) -> Void)? {
        get { forwarder.onCursorWarp }
        set { forwarder.onCursorWarp = newValue }
    }

    func detectMenuBarApps() async -> [DetectedMenuBarApp] {
        let snapshot = runningAppsSnapshot()
        let apps = await itemService.scan(
            candidates: snapshot.candidates,
            ownBundleID: Bundle.main.bundleIdentifier
        )
        guard !Task.isCancelled else { return [] }
        hider.learn(apps)
        return apps
    }

    func displayName(for bundleID: String) -> String {
        hider.displayName(for: bundleID) ?? bundleID
    }

    func bind(omniButton: NSStatusBarButton, statusItem: NSStatusItem) {
        self.omniButton = omniButton
        omniStatusItem = statusItem
        statusItem.isVisible = !hider.isConcealing
    }

    private func handleConcealingChanged(_ concealing: Bool) {
        omniStatusItem?.isVisible = !concealing
        if concealing {
            syncFallbackIcon()
        } else {
            fallbackIcon.dismiss()
        }
    }

    private func syncFallbackIcon() {
        guard hider.isConcealing,
              let placements = fallbackPlacementsProvider?(), !placements.isEmpty
        else {
            fallbackIcon.dismiss()
            return
        }
        fallbackIcon.show(placements: placements)
    }

    func setup() {
        if didBecomeActiveObserver == nil,
           appLaunchObserver == nil,
           appTerminationObserver == nil,
           screenParametersObserver == nil
        {
            observerGeneration &+= 1
        }
        itemService.start()
        installDidBecomeActiveObserver(generation: observerGeneration)
        installRunningApplicationObservers(generation: observerGeneration)
        installApplicationActivationObserver(generation: observerGeneration)
        installScreenParametersObserver(generation: observerGeneration)
        applySettings()
    }

    func applySettings() {
        hider.refreshAvailability()
        cancelCapture()
        let normalizedBundleIDs = HiddenBarSettingsPolicy.normalizedBundleIDs(
            settings.hiddenBarHiddenBundleIDs,
            additionalProtectedBundleIDs: [Bundle.main.bundleIdentifier ?? "com.barut.OmniWM"]
        )
        if settings.hiddenBarHiddenBundleIDs != normalizedBundleIDs {
            settings.hiddenBarHiddenBundleIDs = normalizedBundleIDs
        }
        let configured = Set(normalizedBundleIDs)
        temporarilyRevealed.formIntersection(configured)

        guard Self.wantsRefresh(
            enabled: settings.hiddenBarEnabled,
            available: hider.available,
            hiddenBundleIDs: configured
        ) else {
            cancelTopologyRefresh()
            clearTemporaryReveals()
            hider.drop()
            panel.dismiss()
            iconCache.prune(keeping: [])
            return
        }

        let snapshot = runningAppsSnapshot()
        temporarilyRevealed.formIntersection(snapshot.bundleIDs)
        cancelActivationIfInvalid(configured: configured, snapshot: snapshot)
        cancelReconcealIfNoTemporaryReveals()
        let hiddenRunning = configured.intersection(snapshot.bundleIDs)
        iconCache.prune(keeping: hiddenRunning)
        let unresolved = hiddenRunning.filter { !iconCache.hasResolvedItems(for: $0) }
        reconcileConcealment(snapshot: snapshot, captureBundleIDs: Set(unresolved))
        refreshPanelIfVisible()
        syncFallbackIcon()
    }

    func setEnabled(_ enabled: Bool) {
        settings.hiddenBarEnabled = enabled
        applySettings()
    }

    func togglePanel(placement: HiddenBarPanelPlacement?) {
        guard settings.hiddenBarEnabled, hider.available, let placement else { return }
        if panel.isVisible {
            panel.dismiss()
            return
        }
        handleRefreshEvent()
        panel.toggle(placement: placement, items: currentGlyphs())
    }

    func dismissPanel() {
        panel.dismiss()
    }

    func refreshPanelIfVisible() {
        guard panel.isVisible else { return }
        panel.refresh(items: currentGlyphs())
    }

    func cleanup() {
        observerGeneration &+= 1
        cancelTopologyRefresh()
        cancelCapture()
        forwarder.cancel()
        clearTemporaryReveals()
        panel.dismiss()
        fallbackIcon.dismiss()
        if let didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(didBecomeActiveObserver)
            self.didBecomeActiveObserver = nil
        }
        removeRunningApplicationObservers()
        removeScreenParametersObserver()
        hider.drop()
        itemService.stop()
    }

    func beginPerformanceCapture() {
        performanceCounters = PerformanceCounters()
    }

    func performanceSnapshot() -> PerformanceSnapshot? {
        performanceCounters?.snapshot
    }

    func endPerformanceCapture() -> PerformanceSnapshot? {
        let snapshot = performanceCounters?.snapshot
        performanceCounters = nil
        return snapshot
    }

    private func handleRefreshEvent() {
        performanceCounters?.refreshEvents &+= 1
        syncFallbackIcon()
        let configured = Set(settings.hiddenBarHiddenBundleIDs)
        guard Self.wantsRefresh(
            enabled: settings.hiddenBarEnabled,
            available: hider.available,
            hiddenBundleIDs: configured
        ) else { return }
        let snapshot = runningAppsSnapshot()
        iconCache.prune(keeping: configured.intersection(snapshot.bundleIDs))
        reconcileConcealment(snapshot: snapshot, captureBundleIDs: [])
    }

    private func applyConcealment(
        runningBundleIDs: Set<String>,
        bypassHysteresis: Bool = false
    ) {
        let configured = Set(settings.hiddenBarHiddenBundleIDs)
        guard Self.wantsRefresh(
            enabled: settings.hiddenBarEnabled,
            available: hider.available,
            hiddenBundleIDs: configured
        ) else { return }
        hider.apply(
            hiddenBundleIDs: Self.effectiveHiddenBundleIDs(
                configured: configured,
                temporarilyRevealed: temporarilyRevealed,
                pendingCapture: captureBundleIDs
            ),
            runningBundleIDs: runningBundleIDs,
            bypassHysteresis: bypassHysteresis
        )
    }

    private func reconcileConcealment(
        snapshot: RunningAppsSnapshot,
        captureBundleIDs requestedCaptureBundleIDs: Set<String>,
        bypassHysteresis: Bool = false
    ) {
        let eligible = Self.effectiveHiddenBundleIDs(
            configured: Set(settings.hiddenBarHiddenBundleIDs),
            temporarilyRevealed: temporarilyRevealed
        ).intersection(snapshot.bundleIDs)
        let targets = captureBundleIDs
            .union(requestedCaptureBundleIDs)
            .intersection(eligible)
        guard !targets.isEmpty else {
            if !captureBundleIDs.isEmpty {
                cancelCapture()
            }
            applyConcealment(
                runningBundleIDs: snapshot.bundleIDs,
                bypassHysteresis: bypassHysteresis
            )
            return
        }
        guard targets != captureBundleIDs || captureTask == nil else {
            applyConcealment(
                runningBundleIDs: snapshot.bundleIDs,
                bypassHysteresis: bypassHysteresis
            )
            return
        }
        scheduleCapture(
            bundleIDs: targets,
            snapshot: snapshot,
            bypassHysteresis: bypassHysteresis
        )
    }

    private func scheduleCapture(
        bundleIDs: Set<String>,
        snapshot: RunningAppsSnapshot,
        bypassHysteresis: Bool
    ) {
        let targets = bundleIDs
            .intersection(Self.effectiveHiddenBundleIDs(
                configured: Set(settings.hiddenBarHiddenBundleIDs),
                temporarilyRevealed: temporarilyRevealed
            ))
            .intersection(snapshot.bundleIDs)
        guard !targets.isEmpty else {
            applyConcealment(
                runningBundleIDs: snapshot.bundleIDs,
                bypassHysteresis: bypassHysteresis
            )
            return
        }

        captureTask?.cancel()
        captureGeneration += 1
        captureBundleIDs = targets
        let allowEmptyBundleIDs = targets.filter { iconCache.hasResolvedItems(for: $0) }
        applyConcealment(
            runningBundleIDs: snapshot.bundleIDs,
            bypassHysteresis: true
        )
        let generation = captureGeneration
        captureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let resolution = await itemService.resolveItems(
                candidates: snapshot.candidates,
                bundleIDs: targets,
                allowEmptyBundleIDs: Set(allowEmptyBundleIDs)
            )
            guard !Task.isCancelled, generation == captureGeneration else { return }
            let icons = await HiddenBarIconCaptureService.captureVisible(
                resolution.items,
                timeout: Self.captureDeadline
            )
            guard !Task.isCancelled, generation == captureGeneration else { return }
            finishCapture(
                generation: generation,
                targets: targets,
                resolution: resolution,
                icons: icons
            )
        }
    }

    private func finishCapture(
        generation: Int,
        targets: Set<String>,
        resolution: MenuBarItemResolution,
        icons: [MenuBarItemKey: CapturedIcon]
    ) {
        guard generation == captureGeneration else { return }
        let snapshot = runningAppsSnapshot()
        let validTargets = targets
            .intersection(Set(settings.hiddenBarHiddenBundleIDs))
            .subtracting(temporarilyRevealed)
            .intersection(snapshot.bundleIDs)
        let resolved = resolution.itemsByBundleID.filter { validTargets.contains($0.key) }
        let captured = icons.filter { validTargets.contains($0.key.bundleID) }
        iconCache.replaceResolvedItems(
            resolved,
            capturedIcons: captured,
            replacingCapturedIcons: true
        )
        captureTask = nil
        captureBundleIDs.removeAll(keepingCapacity: true)
        applyConcealment(runningBundleIDs: snapshot.bundleIDs, bypassHysteresis: true)
    }

    private func cancelCapture() {
        captureGeneration += 1
        captureTask?.cancel()
        captureTask = nil
        captureBundleIDs.removeAll(keepingCapacity: true)
    }

    private func refreshVisibleIcons(_ bundleIDs: Set<String>) async {
        let snapshot = runningAppsSnapshot()
        let targets = bundleIDs.intersection(snapshot.bundleIDs)
        guard !targets.isEmpty else { return }
        let resolution = await itemService.resolveItems(
            candidates: snapshot.candidates,
            bundleIDs: targets,
            allowEmptyBundleIDs: targets.filter { iconCache.hasResolvedItems(for: $0) }
        )
        guard !Task.isCancelled else { return }
        let icons = await HiddenBarIconCaptureService.captureVisible(
            resolution.items,
            timeout: Self.captureDeadline
        )
        guard !Task.isCancelled else { return }
        let currentSnapshot = runningAppsSnapshot()
        let validTargets = targets
            .intersection(Set(settings.hiddenBarHiddenBundleIDs))
            .intersection(temporarilyRevealed)
            .intersection(currentSnapshot.bundleIDs)
        guard !validTargets.isEmpty else { return }
        let resolved = resolution.itemsByBundleID.filter { validTargets.contains($0.key) }
        let captured = icons.filter { validTargets.contains($0.key.bundleID) }
        iconCache.replaceResolvedItems(
            resolved,
            capturedIcons: captured,
            replacingCapturedIcons: true
        )
    }

    private func currentGlyphs() -> [HiddenBarGlyph] {
        var appsByBundleID: [String: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications {
            if let bundleID = app.bundleIdentifier, appsByBundleID[bundleID] == nil {
                appsByBundleID[bundleID] = app
            }
        }
        var glyphs: [HiddenBarGlyph] = []
        for bundleID in settings.hiddenBarHiddenBundleIDs {
            guard let app = appsByBundleID[bundleID] else { continue }
            let name = app.localizedName ?? displayName(for: bundleID)
            guard let resolved = iconCache.resolvedItems(for: bundleID) else {
                glyphs.append(
                    HiddenBarGlyph(
                        key: MenuBarItemKey(bundleID: bundleID, ordinal: 0),
                        name: name,
                        image: app.icon,
                        size: CGSize(width: 20, height: 20)
                    )
                )
                continue
            }
            guard !resolved.isEmpty else { continue }
            for item in resolved {
                if let icon = item.icon {
                    let size = CGSize(
                        width: CGFloat(icon.image.width) / icon.scale,
                        height: CGFloat(icon.image.height) / icon.scale
                    )
                    glyphs.append(HiddenBarGlyph(
                        key: item.key,
                        name: name,
                        image: NSImage(cgImage: icon.image, size: size),
                        size: size
                    ))
                } else {
                    glyphs.append(HiddenBarGlyph(
                        key: item.key,
                        name: name,
                        image: app.icon,
                        size: CGSize(width: 20, height: 20)
                    ))
                }
            }
        }
        return glyphs
    }

    private func activateHiddenItem(_ key: MenuBarItemKey) {
        guard settings.hiddenBarEnabled, hider.available,
              Set(settings.hiddenBarHiddenBundleIDs).contains(key.bundleID)
        else { return }
        let cachedItems = iconCache.resolvedSnapshot(for: key.bundleID)
        let cachedItem = cachedItems?.first { $0.key == key }
        let cachedIcons = iconCache.icons.filter { $0.key.bundleID == key.bundleID }
        guard let owner = Self.activationOwner(
            bundleID: key.bundleID,
            selectedItem: cachedItem,
            cachedItems: cachedItems,
            runningCandidates: runningAppsSnapshot().candidates
        ) else { return }
        suspendReconceal()
        guard temporarilyReveal(key.bundleID, ownerPID: owner.pid) else {
            cancelActivationIfInvalid(
                configured: Set(settings.hiddenBarHiddenBundleIDs),
                snapshot: runningAppsSnapshot()
            )
            if Self.shouldResumeReconcealAfterFailedReveal(
                hasTemporaryReveals: !temporarilyRevealed.isEmpty,
                activationInFlight: activationTask != nil
            ) {
                scheduleReconceal()
            }
            return
        }
        activationTask?.cancel()
        activationGeneration += 1
        let generation = activationGeneration
        let activation = ActiveActivation(bundleID: key.bundleID, pid: owner.pid, generation: generation)
        activeActivation = activation
        activationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard let freshItems = await resolveRevealedItems(
                for: key.bundleID,
                owner: owner
            ) else {
                finishActivation(activation)
                return
            }
            guard activationIsValid(activation) else {
                cancelActivationIfCurrent(activation, removeReveal: true)
                return
            }
            let freshIcons = await HiddenBarIconCaptureService.captureVisible(
                freshItems,
                timeout: Self.captureDeadline
            )
            guard activationIsValid(activation) else {
                cancelActivationIfCurrent(activation, removeReveal: true)
                return
            }
            let target = Self.activationTarget(
                for: key,
                cachedItems: cachedItems,
                cachedIcons: cachedIcons,
                freshItems: freshItems,
                freshIcons: freshIcons
            )
            guard activationIsValid(activation) else {
                cancelActivationIfCurrent(activation, removeReveal: true)
                return
            }
            iconCache.replaceResolvedItems(
                [key.bundleID: freshItems],
                capturedIcons: freshIcons,
                replacingCapturedIcons: true
            )
            guard activationIsValid(activation) else {
                cancelActivationIfCurrent(activation, removeReveal: true)
                return
            }
            if let target {
                await forwarder.forward(to: target)
            }
            finishActivation(activation)
        }
    }

    nonisolated static func activationTarget(
        for key: MenuBarItemKey,
        cachedItems: [ResolvedMenuBarItem]?,
        cachedIcons: [MenuBarItemKey: CapturedIcon],
        freshItems: [ResolvedMenuBarItem],
        freshIcons: [MenuBarItemKey: CapturedIcon]
    ) -> ResolvedMenuBarItem? {
        guard let cachedItem = cachedItems?.first(where: { $0.key == key }) else { return nil }
        let cachedSameProcessItems = cachedItems?.filter { $0.pid == cachedItem.pid } ?? []
        let freshSameProcessItems = freshItems.filter { $0.pid == cachedItem.pid }
        if let semanticIdentity = cachedItem.semanticIdentity {
            guard cachedSameProcessItems.count(where: { $0.semanticIdentity == semanticIdentity }) == 1 else {
                return nil
            }
            let matches = freshSameProcessItems.filter { $0.semanticIdentity == semanticIdentity }
            return matches.count == 1 ? matches[0] : nil
        }
        guard let cachedIcon = cachedIcons[key] else { return nil }
        guard cachedSameProcessItems.allSatisfy({ cachedIcons[$0.key] != nil }),
              freshSameProcessItems.allSatisfy({ freshIcons[$0.key] != nil }),
              cachedSameProcessItems.count(where: { item in
                  guard let icon = cachedIcons[item.key] else { return false }
                  return HiddenBarIconCache.isVisuallyEqual(cachedIcon, icon)
              }) == 1
        else { return nil }
        let matches = freshSameProcessItems.filter { item in
            guard let freshIcon = freshIcons[item.key] else { return false }
            return HiddenBarIconCache.isVisuallyEqual(cachedIcon, freshIcon)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    nonisolated static func activationOwner(
        bundleID: String,
        selectedItem: ResolvedMenuBarItem?,
        cachedItems: [ResolvedMenuBarItem]?,
        runningCandidates: [MenuBarAppCandidate]
    ) -> HiddenBarActivationOwner? {
        let candidatePIDs = Set(
            runningCandidates.lazy
                .filter { $0.bundleID == bundleID }
                .map(\.pid)
        )
        if let selectedItem {
            guard selectedItem.key.bundleID == bundleID,
                  candidatePIDs.contains(selectedItem.pid)
            else { return nil }
            return HiddenBarActivationOwner(pid: selectedItem.pid, allowsAuthoritativeEmpty: true)
        }
        let cachedPIDs = Set(
            (cachedItems ?? []).lazy
                .filter { $0.key.bundleID == bundleID }
                .map(\.pid)
        )
        if !cachedPIDs.isEmpty {
            guard cachedPIDs.count == 1, let pid = cachedPIDs.first,
                  candidatePIDs.contains(pid)
            else { return nil }
            return HiddenBarActivationOwner(pid: pid, allowsAuthoritativeEmpty: true)
        }
        guard candidatePIDs.count == 1, let pid = candidatePIDs.first else { return nil }
        return HiddenBarActivationOwner(pid: pid, allowsAuthoritativeEmpty: false)
    }

    nonisolated static func shouldResumeReconcealAfterFailedReveal(
        hasTemporaryReveals: Bool,
        activationInFlight: Bool
    ) -> Bool {
        hasTemporaryReveals && !activationInFlight
    }

    nonisolated static func activationContextIsValid(
        bundleID: String,
        pid: pid_t,
        configuredBundleIDs: Set<String>,
        temporarilyRevealedBundleIDs: Set<String>,
        runningCandidates: [MenuBarAppCandidate]
    ) -> Bool {
        configuredBundleIDs.contains(bundleID)
            && temporarilyRevealedBundleIDs.contains(bundleID)
            && runningCandidates.contains { $0.bundleID == bundleID && $0.pid == pid }
    }

    private func resolveRevealedItems(
        for bundleID: String,
        owner: HiddenBarActivationOwner
    ) async -> [ResolvedMenuBarItem]? {
        let snapshot = runningAppsSnapshot()
        let candidates = snapshot.candidates.filter { $0.bundleID == bundleID && $0.pid == owner.pid }
        guard !candidates.isEmpty else { return nil }
        let resolution = await itemService.resolveItems(
            candidates: candidates,
            bundleIDs: [bundleID],
            allowEmptyBundleIDs: owner.allowsAuthoritativeEmpty ? [bundleID] : []
        )
        guard !Task.isCancelled, temporarilyRevealed.contains(bundleID),
              let items = resolution.itemsByBundleID[bundleID]
        else { return nil }
        return items
    }

    private func temporarilyReveal(_ bundleID: String, ownerPID: pid_t) -> Bool {
        guard settings.hiddenBarEnabled, hider.available else { return false }
        let hidden = Set(settings.hiddenBarHiddenBundleIDs)
        let snapshot = runningAppsSnapshot()
        guard hidden.contains(bundleID),
              snapshot.candidates.contains(where: { $0.bundleID == bundleID && $0.pid == ownerPID })
        else { return false }

        temporarilyRevealed.insert(bundleID)
        reconcileConcealment(
            snapshot: snapshot,
            captureBundleIDs: [],
            bypassHysteresis: true
        )
        guard !hider.conceals(bundleID) else {
            temporarilyRevealed.remove(bundleID)
            return false
        }
        return true
    }

    private func finishActivation(_ activation: ActiveActivation) {
        guard activationIsValid(activation) else {
            cancelActivationIfCurrent(activation, removeReveal: true)
            return
        }
        activeActivation = nil
        activationTask = nil
        if temporarilyRevealed.contains(activation.bundleID) {
            scheduleReconceal()
        }
    }

    private func activationIsValid(_ activation: ActiveActivation) -> Bool {
        guard !Task.isCancelled,
              activation.generation == activationGeneration,
              activeActivation == activation
        else { return false }
        return Self.activationContextIsValid(
            bundleID: activation.bundleID,
            pid: activation.pid,
            configuredBundleIDs: Set(settings.hiddenBarHiddenBundleIDs),
            temporarilyRevealedBundleIDs: temporarilyRevealed,
            runningCandidates: runningAppsSnapshot().candidates
        )
    }

    private func cancelActivationIfInvalid(configured: Set<String>, snapshot: RunningAppsSnapshot) {
        guard let activation = activeActivation,
              !Self.activationContextIsValid(
                  bundleID: activation.bundleID,
                  pid: activation.pid,
                  configuredBundleIDs: configured,
                  temporarilyRevealedBundleIDs: temporarilyRevealed,
                  runningCandidates: snapshot.candidates
              )
        else { return }
        cancelActivationIfCurrent(activation, removeReveal: true)
    }

    private func cancelActivationIfCurrent(_ activation: ActiveActivation, removeReveal: Bool) {
        guard activeActivation == activation else { return }
        if removeReveal {
            temporarilyRevealed.remove(activation.bundleID)
        }
        activationGeneration += 1
        activationTask?.cancel()
        activationTask = nil
        activeActivation = nil
        if !temporarilyRevealed.isEmpty {
            scheduleReconceal()
        }
    }

    private func suspendReconceal() {
        if reconcealTask != nil {
            performanceCounters?.reconcealTasksCancelled &+= 1
            performanceCounters?.terminalReason = .cancelled
        }
        reconcealGeneration += 1
        reconcealTask?.cancel()
        reconcealTask = nil
    }

    private func scheduleReconceal() {
        if reconcealTask != nil {
            performanceCounters?.reconcealTasksCancelled &+= 1
            performanceCounters?.terminalReason = .superseded
        }
        reconcealTask?.cancel()
        reconcealGeneration += 1
        let generation = reconcealGeneration
        let interval = SettingsStore.validatedHiddenBarRehideIntervalSeconds(
            settings.hiddenBarRehideIntervalSeconds
        )
        performanceCounters?.reconcealTasksStarted &+= 1
        reconcealTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let startedAt = menuGuardNow()
            var remaining = Duration.seconds(interval)
            var lastSample = startedAt
            var previousMenuOpen: Bool?
            var consecutiveDeferrals = 0
            var consecutiveUnknownStates = 0
            while remaining > .zero, !Task.isCancelled {
                try? await menuGuardSleeper(
                    Self.menuGuardRetryDelay(consecutiveDeferrals: consecutiveDeferrals)
                )
                guard !Task.isCancelled, generation == reconcealGeneration else { return }
                guard !terminateMenuGuardIfWatchdogExpired(startedAt: startedAt) else { return }
                let ownerPIDs = menuOwnerPIDs(for: temporarilyRevealed)
                performanceCounters?.menuGuardQueries &+= 1
                let menuOpen = await menuOpen(ownerPIDs: ownerPIDs)
                guard !Task.isCancelled, generation == reconcealGeneration else { return }
                guard !terminateMenuGuardIfWatchdogExpired(startedAt: startedAt) else { return }
                let now = menuGuardNow()
                remaining = Self.rehideRemaining(
                    remaining: remaining,
                    elapsed: lastSample.duration(to: now),
                    previousMenuOpen: previousMenuOpen,
                    menuOpen: menuOpen
                )
                lastSample = now
                previousMenuOpen = menuOpen
                guard !recordMenuGuardResult(
                    menuOpen,
                    consecutiveDeferrals: &consecutiveDeferrals,
                    consecutiveUnknownStates: &consecutiveUnknownStates
                ) else { return }
            }
            guard !Task.isCancelled, generation == reconcealGeneration else { return }
            while !Task.isCancelled, generation == reconcealGeneration {
                guard !terminateMenuGuardIfWatchdogExpired(startedAt: startedAt) else { return }
                let revealed = temporarilyRevealed
                guard !revealed.isEmpty else {
                    performanceCounters?.terminalReason = .noRevealedItems
                    reconcealTask = nil
                    return
                }
                let ownerPIDs = menuOwnerPIDs(for: revealed)
                performanceCounters?.menuGuardQueries &+= 1
                let menuOpenBeforeRefresh = await menuOpen(ownerPIDs: ownerPIDs)
                guard !Task.isCancelled, generation == reconcealGeneration else { return }
                guard !terminateMenuGuardIfWatchdogExpired(startedAt: startedAt) else { return }
                if menuOpenBeforeRefresh != false {
                    guard !recordMenuGuardResult(
                        menuOpenBeforeRefresh,
                        consecutiveDeferrals: &consecutiveDeferrals,
                        consecutiveUnknownStates: &consecutiveUnknownStates
                    ) else { return }
                    try? await menuGuardSleeper(
                        Self.menuGuardRetryDelay(consecutiveDeferrals: consecutiveDeferrals)
                    )
                    continue
                }
                _ = recordMenuGuardResult(
                    menuOpenBeforeRefresh,
                    consecutiveDeferrals: &consecutiveDeferrals,
                    consecutiveUnknownStates: &consecutiveUnknownStates
                )
                await refreshVisibleIcons(revealed)
                guard !Task.isCancelled, generation == reconcealGeneration else { return }
                guard !terminateMenuGuardIfWatchdogExpired(startedAt: startedAt) else { return }
                performanceCounters?.menuGuardQueries &+= 1
                let menuOpenAfterRefresh = await menuOpen(
                    ownerPIDs: menuOwnerPIDs(for: temporarilyRevealed)
                )
                guard !Task.isCancelled, generation == reconcealGeneration else { return }
                guard !terminateMenuGuardIfWatchdogExpired(startedAt: startedAt) else { return }
                guard menuOpenAfterRefresh == false else {
                    guard !recordMenuGuardResult(
                        menuOpenAfterRefresh,
                        consecutiveDeferrals: &consecutiveDeferrals,
                        consecutiveUnknownStates: &consecutiveUnknownStates
                    ) else { return }
                    try? await menuGuardSleeper(
                        Self.menuGuardRetryDelay(consecutiveDeferrals: consecutiveDeferrals)
                    )
                    continue
                }
                temporarilyRevealed.subtract(revealed)
                applyConcealment(
                    runningBundleIDs: runningAppsSnapshot().bundleIDs,
                    bypassHysteresis: true
                )
                performanceCounters?.terminalReason = .concealed
                reconcealTask = nil
                return
            }
        }
    }

    private func clearTemporaryReveals() {
        if reconcealTask != nil {
            performanceCounters?.reconcealTasksCancelled &+= 1
            performanceCounters?.terminalReason = .cancelled
        }
        reconcealGeneration += 1
        reconcealTask?.cancel()
        reconcealTask = nil
        activationGeneration += 1
        activationTask?.cancel()
        activationTask = nil
        activeActivation = nil
        temporarilyRevealed.removeAll()
    }

    private func cancelReconcealIfNoTemporaryReveals() {
        guard temporarilyRevealed.isEmpty, reconcealTask != nil else { return }
        reconcealGeneration += 1
        performanceCounters?.reconcealTasksCancelled &+= 1
        performanceCounters?.terminalReason = .noRevealedItems
        reconcealTask?.cancel()
        reconcealTask = nil
    }

    private struct RunningAppsSnapshot {
        let bundleIDs: Set<String>
        let candidates: [MenuBarAppCandidate]
    }

    private func runningAppsSnapshot() -> RunningAppsSnapshot {
        let applications = NSWorkspace.shared.runningApplications
        var bundleIDs: Set<String> = []
        var candidates: [MenuBarAppCandidate] = []
        bundleIDs.reserveCapacity(applications.count)
        candidates.reserveCapacity(applications.count)
        for app in applications {
            guard let bundleID = app.bundleIdentifier else { continue }
            bundleIDs.insert(bundleID)
            candidates.append(MenuBarAppCandidate(
                bundleID: bundleID,
                pid: app.processIdentifier,
                name: app.localizedName ?? bundleID
            ))
        }
        return RunningAppsSnapshot(bundleIDs: bundleIDs, candidates: candidates)
    }

    private func menuOwnerPIDs(for bundleIDs: Set<String>) -> Set<pid_t> {
        guard !bundleIDs.isEmpty else { return [] }
        return Set(NSWorkspace.shared.runningApplications.compactMap { app in
            app.bundleIdentifier.map(bundleIDs.contains) == true ? app.processIdentifier : nil
        })
    }

    nonisolated static func wantsRefresh(
        enabled: Bool,
        available: Bool,
        hiddenBundleIDs: Set<String>
    ) -> Bool {
        enabled && available && !hiddenBundleIDs.isEmpty
    }

    nonisolated static func effectiveHiddenBundleIDs(
        configured: Set<String>,
        temporarilyRevealed: Set<String>,
        pendingCapture: Set<String> = []
    ) -> Set<String> {
        configured.subtracting(temporarilyRevealed).subtracting(pendingCapture)
    }

    nonisolated static func rehideRemaining(
        remaining: Duration,
        elapsed: Duration,
        previousMenuOpen: Bool?,
        menuOpen: Bool?
    ) -> Duration {
        guard previousMenuOpen == false, menuOpen == false else { return remaining }
        return max(.zero, remaining - max(.zero, elapsed))
    }

    nonisolated static func menuGuardRetryDelay(consecutiveDeferrals: Int) -> Duration {
        menuGuardRetryDelays[min(max(0, consecutiveDeferrals), menuGuardRetryDelays.count - 1)]
    }

    nonisolated static func shouldTerminateMenuGuardForUnknownState(consecutiveUnknownStates: Int) -> Bool {
        consecutiveUnknownStates >= maximumConsecutiveUnknownMenuStates
    }

    nonisolated static func menuGuardWatchdogExpired(elapsed: Duration) -> Bool {
        elapsed >= menuGuardWatchdogDuration
    }

    private func recordMenuGuardDeferral(_ consecutiveDeferrals: Int) {
        guard var counters = performanceCounters else { return }
        counters.menuGuardDeferrals &+= 1
        counters.maximumConsecutiveDeferrals = max(
            counters.maximumConsecutiveDeferrals,
            consecutiveDeferrals
        )
        performanceCounters = counters
    }

    private func recordMenuGuardResult(
        _ menuOpen: Bool?,
        consecutiveDeferrals: inout Int,
        consecutiveUnknownStates: inout Int
    ) -> Bool {
        guard menuOpen != false else {
            consecutiveDeferrals = 0
            consecutiveUnknownStates = 0
            return false
        }
        consecutiveDeferrals += 1
        consecutiveUnknownStates = menuOpen == nil ? consecutiveUnknownStates + 1 : 0
        recordMenuGuardDeferral(consecutiveDeferrals)
        guard Self.shouldTerminateMenuGuardForUnknownState(
            consecutiveUnknownStates: consecutiveUnknownStates
        ) else { return false }
        forceTerminalConcealment(reason: .unknownStateLimit)
        return true
    }

    private func terminateMenuGuardIfWatchdogExpired(
        startedAt: ContinuousClock.Instant
    ) -> Bool {
        guard Self.menuGuardWatchdogExpired(elapsed: startedAt.duration(to: menuGuardNow())) else {
            return false
        }
        forceTerminalConcealment(reason: .watchdog)
        return true
    }

    private func forceTerminalConcealment(reason: MenuGuardTerminalReason) {
        temporarilyRevealed.removeAll(keepingCapacity: true)
        applyConcealment(
            runningBundleIDs: runningAppsSnapshot().bundleIDs,
            bypassHysteresis: true
        )
        performanceCounters?.terminalReason = reason
        reconcealTask = nil
    }

    private func menuOpen(ownerPIDs: Set<pid_t>) async -> Bool? {
        if let menuOpenProviderForTests {
            return await menuOpenProviderForTests(ownerPIDs)
        }
        return await itemService.isMenuOpen(ownerPIDs: ownerPIDs)
    }

    func startReconcealForTests(revealedBundleIDs: Set<String>) {
        temporarilyRevealed = revealedBundleIDs
        scheduleReconceal()
    }

    var temporarilyRevealedBundleIDsForTests: Set<String> {
        temporarilyRevealed
    }

    private func installDidBecomeActiveObserver(generation: Int) {
        guard didBecomeActiveObserver == nil else { return }
        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.enqueueObserverEvent(.didBecomeActive, generation: generation)
        }
    }

    private func installRunningApplicationObservers(generation: Int) {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        if appLaunchObserver == nil {
            appLaunchObserver = notificationCenter.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let bundleID = app?.bundleIdentifier
                self?.enqueueObserverEvent(
                    .runningApplicationChanged(bundleID: bundleID, terminated: false),
                    generation: generation
                )
            }
        }
        if appTerminationObserver == nil {
            appTerminationObserver = notificationCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let bundleID = app?.bundleIdentifier
                self?.enqueueObserverEvent(
                    .runningApplicationChanged(bundleID: bundleID, terminated: true),
                    generation: generation
                )
            }
        }
    }

    private func installApplicationActivationObserver(generation: Int) {
        guard appActivationObserver == nil else { return }
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.enqueueObserverEvent(.applicationActivated, generation: generation)
        }
    }

    private func installScreenParametersObserver(generation: Int) {
        guard screenParametersObserver == nil else { return }
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.enqueueObserverEvent(.screenParametersChanged, generation: generation)
        }
    }

    private nonisolated func enqueueObserverEvent(_ event: ObserverEvent, generation: Int) {
        Task { @MainActor [weak self] in
            guard let self, generation == observerGeneration else { return }
            switch event {
            case .didBecomeActive:
                hider.refreshAvailability()
                handleRefreshEvent()
            case .applicationActivated:
                handleRefreshEvent()
            case let .runningApplicationChanged(bundleID, terminated):
                handleRunningApplicationChanged(bundleID: bundleID, terminated: terminated)
            case .screenParametersChanged:
                guard hider.isConcealing else { return }
                scheduleTopologyRefresh()
            }
        }
    }

    func enqueueDidBecomeActiveForTests() {
        enqueueObserverEvent(.didBecomeActive, generation: observerGeneration)
    }

    private func removeScreenParametersObserver() {
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
            self.screenParametersObserver = nil
        }
    }

    func scheduleTopologyRefresh() {
        topologyRefreshTask?.cancel()
        topologyRefreshGeneration += 1
        let generation = topologyRefreshGeneration
        topologyRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await topologyRefreshSleeper(Self.topologyRefreshDelay)
            guard !Task.isCancelled, generation == topologyRefreshGeneration else { return }
            topologyRefreshTask = nil
            onTopologyRefreshForTests?()
            syncFallbackIcon()
        }
    }

    private func cancelTopologyRefresh() {
        topologyRefreshGeneration += 1
        topologyRefreshTask?.cancel()
        topologyRefreshTask = nil
    }

    var hasPendingTopologyRefreshForTests: Bool {
        topologyRefreshTask != nil
    }

    var hasScreenParametersObserverForTests: Bool {
        screenParametersObserver != nil
    }

    private func removeRunningApplicationObservers() {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        if let appLaunchObserver {
            notificationCenter.removeObserver(appLaunchObserver)
            self.appLaunchObserver = nil
        }
        if let appTerminationObserver {
            notificationCenter.removeObserver(appTerminationObserver)
            self.appTerminationObserver = nil
        }
        if let appActivationObserver {
            notificationCenter.removeObserver(appActivationObserver)
            self.appActivationObserver = nil
        }
    }

    private func handleRunningApplicationChanged(bundleID: String?, terminated: Bool) {
        let configured = Set(settings.hiddenBarHiddenBundleIDs)
        guard Self.wantsRefresh(
            enabled: settings.hiddenBarEnabled,
            available: hider.available,
            hiddenBundleIDs: configured
        ) else { return }

        if terminated, let bundleID {
            temporarilyRevealed.remove(bundleID)
        }

        let snapshot = runningAppsSnapshot()
        temporarilyRevealed.formIntersection(snapshot.bundleIDs)
        cancelActivationIfInvalid(configured: configured, snapshot: snapshot)
        cancelReconcealIfNoTemporaryReveals()
        iconCache.prune(keeping: configured.intersection(snapshot.bundleIDs))
        let captures: Set<String>
        if !terminated, let bundleID, configured.contains(bundleID) {
            captures = [bundleID]
        } else {
            captures = []
        }
        reconcileConcealment(snapshot: snapshot, captureBundleIDs: captures)
        refreshPanelIfVisible()
    }
}
