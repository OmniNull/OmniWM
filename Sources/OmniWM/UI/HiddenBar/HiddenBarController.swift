// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit

@MainActor
final class HiddenBarController {
    private struct ActiveActivation: Equatable {
        let bundleID: String
        let pid: pid_t
        let generation: Int
    }

    let statusItems: HiddenBarStatusItems
    let observation = HiddenBarObservation()
    let capture: HiddenBarCaptureSession
    let reconcealment: HiddenBarReconcealment
    let menuSession = HiddenBarMenuSession()
    let settings: SettingsStore
    let hider: NativeMenuBarHider
    private let itemService: MenuBarItemService
    let iconCache = HiddenBarIconCache()
    private let forwarder: HiddenBarClickForwarder
    private let setMenuAccess: (Bool) -> Bool

    private var activationTask: Task<Void, Never>?
    private var activationGeneration = 0
    private var activeActivation: ActiveActivation?
    var temporarilyRevealed: Set<String> = [] {
        didSet {
            if !oldValue.isEmpty, temporarilyRevealed.isEmpty {
                _ = setMenuAccess(false)
            }
        }
    }

    private var didSetup = false
    let performance = HiddenBarPerformanceCapture()

    init(
        settings: SettingsStore,
        hider: NativeMenuBarHider = NativeMenuBarHider(),
        setMenuAccess: @escaping (Bool) -> Bool = { _ in true }
    ) {
        self.hider = hider
        self.settings = settings
        self.setMenuAccess = setMenuAccess
        let itemService = MenuBarItemService()
        self.itemService = itemService
        forwarder = HiddenBarClickForwarder(itemService: itemService)
        statusItems = HiddenBarStatusItems()
        capture = HiddenBarCaptureSession(itemService: itemService, iconCache: iconCache)
        reconcealment = HiddenBarReconcealment(itemService: itemService, performance: performance)
        capture.connect(controller: self)
        reconcealment.connect(controller: self)
        observation.connect(controller: self)
        iconCache.onChange = { [weak self] in
            self?.refreshPanelIfVisible()
        }
    }

    func isExemptWindow(_ window: NSWindow) -> Bool {
        statusItems.ownsStatusItemWindow(window) || WorkspaceBarMenuButton.contains(NSApp.currentEvent, in: window)
    }

    var isHidingAvailable: Bool {
        hider.available
    }

    var onCursorWarp: ((CGPoint) -> Void)? {
        get { forwarder.onCursorWarp }
        set { forwarder.onCursorWarp = newValue }
    }

    func systemSettingsAllowance() -> [String: Bool] {
        hider.systemSettingsAllowance()
    }

    func setup() {
        guard !didSetup else { return }
        didSetup = true
        applySettings()
    }

    func applySettings() {
        let normalizedBundleIDs = HiddenBarSettingsPolicy.normalizedBundleIDs(
            settings.hiddenBar.hiddenBundleIDs,
            additionalProtectedBundleIDs: [Bundle.main.bundleIdentifier ?? "com.barut.OmniWM"]
        )
        if settings.hiddenBar.hiddenBundleIDs != normalizedBundleIDs {
            settings.hiddenBar.hiddenBundleIDs = normalizedBundleIDs
        }
        guard settings.effectiveHiddenBarEnabled else {
            deactivate()
            return
        }
        guard didSetup else { return }

        if !itemService.isRunning {
            itemService.start()
        }
        observation.start()
        observation.install()
        hider.refreshAvailability()
        capture.cancel()
        let configured = Set(normalizedBundleIDs)
        if let bundleID = menuSession.bundleID, !configured.contains(bundleID) {
            dismissPanel()
        }
        temporarilyRevealed.formIntersection(configured)

        guard HiddenBarConcealmentPolicy.wantsRefresh(
            enabled: settings.effectiveHiddenBarEnabled,
            available: hider.available,
            hiddenBundleIDs: configured
        ) else {
            clearTemporaryReveals()
            hider.drop()
            dismissPanel()
            iconCache.prune(keeping: [])
            return
        }

        let snapshot = HiddenBarRunningAppsSnapshot.current()
        temporarilyRevealed.formIntersection(snapshot.bundleIDs)
        cancelActivationIfInvalid(configured: configured, snapshot: snapshot)
        cancelReconcealIfNoTemporaryReveals()
        let hiddenRunning = configured.intersection(snapshot.bundleIDs)
        iconCache.prune(keeping: hiddenRunning)
        let unresolved = hiddenRunning.filter { !iconCache.hasResolvedItems(for: $0) }
        capture.reconcile(snapshot: snapshot, captureBundleIDs: Set(unresolved))
        refreshPanelIfVisible()
    }

    func setEnabled(_ enabled: Bool) {
        settings.hiddenBar.enabled = enabled
        applySettings()
    }

    var shellDrawer: HiddenBarShellDrawer?

    func toggleDrawer(on monitorId: Monitor.ID?, placement: HiddenBarPanelPlacement?) {
        guard let shellDrawer, shellDrawer.isActive() else { return }
        if shellDrawer.isOpen() {
            shellDrawer.close(true)
            return
        }
        guard settings.effectiveHiddenBarEnabled, hider.available, let placement else { return }
        refreshItems()
        shellDrawer.show(currentGlyphs(), monitorId, placement)
    }

    func activate(_ key: MenuBarItemKey) {
        activateHiddenItem(key)
    }

    func openMenu(_ key: MenuBarItemKey, onOpen: @escaping (HiddenBarMenuSession.OpenResult) -> Void) {
        menuSession.close()
        if let activeActivation {
            cancelActivationIfCurrent(activeActivation, removeReveal: false)
        }
        forwarder.cancel()
        guard settings.effectiveHiddenBarEnabled, hider.available,
              settings.hiddenBar.hiddenBundleIDs.contains(key.bundleID)
        else {
            Log.hiddenBar.error("Menu acquisition is disabled or unavailable for \(key.bundleID)")
            onOpen(.unavailable)
            return
        }
        let cachedItems = iconCache.resolvedSnapshot(for: key.bundleID)
        guard let owner = HiddenBarActivationPolicy.activationOwner(
            bundleID: key.bundleID,
            selectedItem: cachedItems?.first(where: { $0.key == key }),
            cachedItems: cachedItems,
            runningCandidates: HiddenBarRunningAppsSnapshot.current().candidates
        ) else {
            Log.hiddenBar.error("No unique current menu item owner for \(key.bundleID)")
            onOpen(.unavailable)
            return
        }
        reconcealment.cancel(reason: .cancelled)
        guard temporarilyReveal(key.bundleID, ownerPID: owner.pid) else {
            Log.hiddenBar.error("Could not reveal menu item for \(key.bundleID), PID \(owner.pid)")
            releaseMenuReveal(key.bundleID)
            onOpen(.unavailable)
            return
        }
        menuSession.acquire(
            target: .init(key: key, ownerPID: owner.pid, cachedItems: cachedItems),
            resolve: { [weak self] in
                await self?.resolveRevealedItems(
                    for: key.bundleID,
                    owner: owner
                )
            },
            onResolve: { [weak self] items in
                if cachedItems == nil {
                    self?.iconCache.replaceResolvedItems([key.bundleID: items])
                }
            },
            release: { [weak self] disposition in self?.releaseMenuReveal(key.bundleID, disposition: disposition) },
            onOpen: onOpen
        )
    }

    private func releaseMenuReveal(
        _ bundleID: String,
        disposition: HiddenBarMenuSession.RevealDisposition = .conceal
    ) {
        if disposition == .conceal {
            concealRevealed([bundleID])
        }
        if !temporarilyRevealed.isEmpty {
            reconcealment.schedule(intervalSeconds: settings.hiddenBar.resolvedRehideIntervalSeconds)
        }
    }

    private func currentGlyphs() -> [HiddenBarGlyph] {
        HiddenBarGlyphProjection.current(bundleIDs: settings.hiddenBar.hiddenBundleIDs, iconCache: iconCache)
    }

    func dismissPanel() {
        menuSession.close()
        if shellDrawer?.isOpen() == true {
            shellDrawer?.close(false)
        }
    }

    func refreshPanelIfVisible() {
        if shellDrawer?.isOpen() == true {
            shellDrawer?.refresh(currentGlyphs())
        }
    }

    func cleanup() {
        didSetup = false
        deactivate()
    }

    private func deactivate() {
        observation.invalidate()
        capture.cancel()
        forwarder.cancel()
        clearTemporaryReveals()
        dismissPanel()
        observation.removeObservers()
        hider.drop()
        if itemService.isRunning {
            itemService.stop()
        }
        iconCache.prune(keeping: [])
    }

    var isItemServiceRunningForTests: Bool {
        itemService.isRunning
    }

    func refreshAvailabilityAndItems() {
        hider.refreshAvailability()
        refreshItems()
    }

    func refreshItems() {
        performance.recordRefresh()
        let configured = Set(settings.hiddenBar.hiddenBundleIDs)
        guard HiddenBarConcealmentPolicy.wantsRefresh(
            enabled: settings.effectiveHiddenBarEnabled,
            available: hider.available,
            hiddenBundleIDs: configured
        ) else { return }
        let snapshot = HiddenBarRunningAppsSnapshot.current()
        iconCache.prune(keeping: configured.intersection(snapshot.bundleIDs))
        capture.reconcile(snapshot: snapshot, captureBundleIDs: [])
    }
}

extension HiddenBarController {
    private func activateHiddenItem(_ key: MenuBarItemKey) {
        guard settings.effectiveHiddenBarEnabled, hider.available,
              Set(settings.hiddenBar.hiddenBundleIDs).contains(key.bundleID)
        else { return }
        let cachedItems = iconCache.resolvedSnapshot(for: key.bundleID)
        let cachedItem = cachedItems?.first { $0.key == key }
        let cachedIcons = iconCache.icons.filter { $0.key.bundleID == key.bundleID }
        guard let owner = HiddenBarActivationPolicy.activationOwner(
            bundleID: key.bundleID,
            selectedItem: cachedItem,
            cachedItems: cachedItems,
            runningCandidates: HiddenBarRunningAppsSnapshot.current().candidates
        ) else { return }
        reconcealment.cancel(reason: .cancelled)
        guard temporarilyReveal(key.bundleID, ownerPID: owner.pid) else {
            cancelActivationIfInvalid(
                configured: Set(settings.hiddenBar.hiddenBundleIDs),
                snapshot: HiddenBarRunningAppsSnapshot.current()
            )
            if HiddenBarActivationPolicy.shouldResumeReconcealAfterFailedReveal(
                hasTemporaryReveals: !temporarilyRevealed.isEmpty,
                activationInFlight: activationTask != nil
            ) {
                reconcealment.schedule(intervalSeconds: settings.hiddenBar.resolvedRehideIntervalSeconds)
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
            await resolveAndActivate(
                activation,
                key: key,
                owner: owner,
                cachedItems: cachedItems,
                cachedIcons: cachedIcons
            )
        }
    }

    private func resolveAndActivate(
        _ activation: ActiveActivation,
        key: MenuBarItemKey,
        owner: HiddenBarActivationOwner,
        cachedItems: [ResolvedMenuBarItem]?,
        cachedIcons: [MenuBarItemKey: CapturedIcon]
    ) async {
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
            timeout: HiddenBarIconCaptureService.captureDeadline
        )
        guard activationIsValid(activation) else {
            cancelActivationIfCurrent(activation, removeReveal: true)
            return
        }
        let target = HiddenBarActivationPolicy.activationTarget(
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

    private func resolveRevealedItems(
        for bundleID: String,
        owner: HiddenBarActivationOwner
    ) async -> [ResolvedMenuBarItem]? {
        let snapshot = HiddenBarRunningAppsSnapshot.current()
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
        guard settings.effectiveHiddenBarEnabled, hider.available else { return false }
        let hidden = Set(settings.hiddenBar.hiddenBundleIDs)
        let snapshot = HiddenBarRunningAppsSnapshot.current()
        guard hidden.contains(bundleID),
              snapshot.candidates.contains(where: { $0.bundleID == bundleID && $0.pid == ownerPID })
        else { return false }

        guard !temporarilyRevealed.isEmpty || setMenuAccess(true) else { return false }
        temporarilyRevealed.insert(bundleID)
        capture.reconcile(
            snapshot: snapshot,
            captureBundleIDs: []
        )
        guard hider.isRevealed(bundleID) else {
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
            reconcealment.schedule(intervalSeconds: settings.hiddenBar.resolvedRehideIntervalSeconds)
        }
    }

    private func activationIsValid(_ activation: ActiveActivation) -> Bool {
        guard !Task.isCancelled,
              activation.generation == activationGeneration,
              activeActivation == activation
        else { return false }
        return HiddenBarActivationPolicy.activationContextIsValid(
            bundleID: activation.bundleID,
            pid: activation.pid,
            configuredBundleIDs: Set(settings.hiddenBar.hiddenBundleIDs),
            temporarilyRevealedBundleIDs: temporarilyRevealed,
            runningCandidates: HiddenBarRunningAppsSnapshot.current().candidates
        )
    }

    func cancelActivationIfInvalid(configured: Set<String>, snapshot: HiddenBarRunningAppsSnapshot) {
        guard let activation = activeActivation,
              !HiddenBarActivationPolicy.activationContextIsValid(
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
            reconcealment.schedule(intervalSeconds: settings.hiddenBar.resolvedRehideIntervalSeconds)
        }
    }

    private func clearTemporaryReveals() {
        reconcealment.cancel(reason: .cancelled)
        activationGeneration += 1
        activationTask?.cancel()
        activationTask = nil
        activeActivation = nil
        temporarilyRevealed.removeAll()
    }

    func cancelReconcealIfNoTemporaryReveals() {
        guard temporarilyRevealed.isEmpty else { return }
        reconcealment.cancelIfRunning(reason: .noRevealedItems)
    }

    func startReconcealForTests(revealedBundleIDs: Set<String>) {
        guard !temporarilyRevealed.isEmpty || revealedBundleIDs.isEmpty || setMenuAccess(true) else { return }
        temporarilyRevealed = revealedBundleIDs
        reconcealment.schedule(intervalSeconds: settings.hiddenBar.resolvedRehideIntervalSeconds)
    }

    var temporarilyRevealedBundleIDsForTests: Set<String> {
        temporarilyRevealed
    }
}
