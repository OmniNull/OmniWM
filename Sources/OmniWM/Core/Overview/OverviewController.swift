// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import QuartzCore

@MainActor
final class OverviewController {
    private(set) weak var wmController: WMController?
    let motionPolicy: MotionPolicy
    private let environment: OverviewEnvironment

    private(set) var state: OverviewState = .closed
    private let overviewSnapshot: OverviewSnapshot
    let drag: OverviewDragSession
    private let mutationSession: OverviewMutationSession
    private let structuralActions: OverviewStructuralActions
    private let projection: OverviewViewportProjection
    var selectedWindowHandle: WindowHandle? {
        projection.selectedWindowHandle
    }

    var activeInteractionMonitorId: Monitor.ID? {
        projection.activeInteractionMonitorId
    }

    private var presentation: OverviewPresentation

    private let thumbnailCapture: OverviewThumbnailCapture
    let windowSession: OverviewWindowSession
    private(set) var animator: OverviewAnimator?

    let focusSession: OverviewFocusSession
    private let inputSession: OverviewInputSession
    let input: OverviewInputHandler

    var canPerformStructuralHotkey: Bool {
        !mutationSession.isTransferring
    }

    var onPrepareActivation: ((WindowHandle, WorkspaceDescriptor.ID) -> Void)?
    var onActivateWindow: ((WindowHandle, WorkspaceDescriptor.ID) -> Void)?
    var onActivateWorkspace: ((WorkspaceDescriptor.ID) -> Bool)?
    var onCloseWindow: ((WindowHandle) -> Bool)?
    private let wallpaperCache = OverviewWallpaperCache()
    var isOpen: Bool {
        state.isOpen
    }

    init(
        wmController: WMController,
        motionPolicy: MotionPolicy,
        environment: OverviewEnvironment = .init(),
        ownedWindowRegistry: OwnedWindowRegistry = .shared,
        previewCapture: OverviewThumbnailCapture? = nil,
        animationInstaller: OverviewAnimator.AnimationInstaller? = nil,
        animationMediaTimeProvider: @escaping OverviewAnimator.MediaTimeProvider = CACurrentMediaTime
    ) {
        presentation = OverviewPresentation(
            settings: wmController.settings,
            isDark: wmController.borderUsesDarkAppearance
        )
        let windowFacts = OverviewWindowFacts(wmController: wmController, environment: environment)
        structuralActions = OverviewStructuralActions(wmController: wmController, windowFacts: windowFacts)
        overviewSnapshot = OverviewSnapshot(wmController: wmController, facts: windowFacts)
        projection = OverviewViewportProjection(
            wmController: wmController,
            snapshot: overviewSnapshot,
            scale: presentation.configuredScale
        )
        focusSession = OverviewFocusSession(
            wmController: wmController,
            environment: environment,
            projection: projection,
            snapshot: overviewSnapshot
        )
        mutationSession = OverviewMutationSession(
            wmController: wmController,
            projection: projection,
            windowFacts: windowFacts,
            structuralActions: structuralActions
        )
        windowSession = OverviewWindowSession(
            projection: projection,
            ownedWindowRegistry: ownedWindowRegistry,
            motionPolicy: motionPolicy
        )
        drag = OverviewDragSession(
            projection: projection,
            snapshot: overviewSnapshot,
            windowSession: windowSession,
            structuralActions: structuralActions,
            mutationSession: mutationSession
        )
        thumbnailCapture = previewCapture ?? OverviewThumbnailCapture()
        input = OverviewInputHandler(
            projection: projection,
            windowSession: windowSession,
            snapshot: overviewSnapshot
        )
        self.wmController = wmController
        self.motionPolicy = motionPolicy
        self.environment = environment
        inputSession = OverviewInputSession(environment: environment)
        connectSession(animationInstaller: animationInstaller, animationMediaTimeProvider: animationMediaTimeProvider)
    }

    private func connectSession(
        animationInstaller: OverviewAnimator.AnimationInstaller?,
        animationMediaTimeProvider: @escaping OverviewAnimator.MediaTimeProvider
    ) {
        drag.connect(overview: self)
        focusSession.connect(overview: self)
        mutationSession.connect(overview: self)
        animator = OverviewAnimator(
            controller: self,
            animationInstaller: animationInstaller,
            mediaTimeProvider: animationMediaTimeProvider
        )
        input.connect(controller: self)
        windowSession.onLayoutsUpdated = { [weak self] in
            self?.updatePreviewVisibility()
        }
        windowSession.previewForHandle = { [weak thumbnailCapture] handle in
            thumbnailCapture?.preview(for: handle)
        }
        windowSession.wallpaperForDisplay = { [weak wallpaperCache] displayId, maxPixelSize in
            wallpaperCache?.image(for: displayId, maxPixelSize: maxPixelSize)
        }
        thumbnailCapture.onPreview = { [weak windowSession] handle, frame in
            windowSession?.updatePreview(frame, for: handle)
        }
        thumbnailCapture.onCaptureStarted = { [weak self] in self?.environment.onThumbnailCaptureStarted() }
    }

    isolated deinit {
        endOwnedSession()
        cleanup()
    }
}

extension OverviewController {
    func toggle() {
        switch state {
        case .closed:
            open()
        case .opening:
            if isInteractiveTransitionActive, transitionProgress < 0.5 {
                commitOpen()
            } else {
                input.dismissToSelection(animated: true)
            }
        case .open:
            input.dismissToSelection(animated: true)
        case .closing:
            reverseClosingTransition()
        }
    }

    func performStructuralHotkey(_ command: HotkeyCommand, selectedHandle: WindowHandle) -> StructuralMutationOutcome? {
        structuralActions.performStructuralHotkey(command, selectedHandle: selectedHandle)
    }

    @discardableResult
    func executeStructuralHotkey(
        _ command: HotkeyCommand,
        selectedHandle: WindowHandle
    ) -> StructuralMutationOutcome? {
        guard !mutationSession.isTransferring else { return .unchanged }
        let outcome = performStructuralHotkey(command, selectedHandle: selectedHandle)
        if let outcome, case let .changed(mutation) = outcome {
            mutationSession.completeStructuralMutation(mutation)
        }
        return outcome
    }

    func open() {
        guard beginOpening() else { return }
        activateForInteraction()
        if motionPolicy.animationsEnabled {
            animator?.startOpenAnimation(displayIds: windowSession.displayIds)
        }
    }

    func beginOpening() -> Bool {
        guard case .closed = state, wmController != nil else { return false }

        focusSession.advancePostCloseHandoffGeneration()
        focusSession.pendingPostCloseHandoffValidity = nil

        prepareOpenState()
        windowSession.createWindows(
            controller: self,
            monitors: wmController?.workspaceManager.monitors ?? [],
            palette: presentation.renderPalette
        )
        beginOwnedSession()

        if motionPolicy.animationsEnabled {
            state = .opening
        } else {
            state = .open
            animator?.settle(at: 1)
        }

        updateWindowDisplays()
        windowSession.showWindows()
        return true
    }

    func resumeOpening() {
        focusSession.advancePostCloseHandoffGeneration()
        focusSession.pendingDismissReason = .cancel
        focusSession.pendingFocusTargetWindow = nil
        focusSession.pendingPostCloseHandoffValidity = nil
        state = motionPolicy.animationsEnabled ? .opening : .open
        projection.settleRestFrames(targetWindow: nil)
        updateWindowDisplays()
    }

    func prepareOpenState() {
        guard let wmController else { return }

        projection.activeInteractionMonitorId = wmController.monitorForInteraction()?.id
        presentation = OverviewPresentation(
            settings: wmController.settings,
            isDark: wmController.borderUsesDarkAppearance
        )
        projection.scale = presentation.configuredScale
        overviewSnapshot.build()

        if let focusedHandle = wmController.workspaceManager.selectedManagedHandle,
           overviewSnapshot.windows[focusedHandle] != nil
        {
            projection.selectedWindowHandle = focusedHandle
        }

        projection.rebuildProjectedLayouts()
    }

    func updateSettings() {
        guard let wmController else { return }

        let (scaleChanged, appearanceChanged) = presentation.update(
            settings: wmController.settings,
            isDark: wmController.borderUsesDarkAppearance
        )

        guard state.isOpen else {
            projection.scale = presentation.configuredScale
            return
        }
        guard scaleChanged || appearanceChanged else { return }

        if scaleChanged {
            let anchors = projection.captureSelectedViewportAnchors()
            projection.scale = presentation.configuredScale
            projection.rebuildProjectedLayouts(preservingSelectedAnchors: anchors)
            updateWindowDisplays(palette: appearanceChanged ? presentation.renderPalette : nil)
        } else {
            windowSession.updatePalette(presentation.renderPalette)
        }
    }

    func dismiss(
        reason: OverviewDismissReason = .cancel,
        targetWindow: WindowHandle? = nil,
        animated: Bool
    ) {
        switch state {
        case .closed:
            return
        case .closing:
            if reason == .externalDeactivation {
                focusSession.pendingDismissReason = .externalDeactivation
                focusSession.pendingFocusTargetWindow = nil
                focusSession.pendingPostCloseHandoffValidity = nil
            }
            return
        case .opening,
             .open:
            break
        }

        if hasActiveDragSession {
            drag.cancelDrag()
        }

        commitOverviewPans()
        let resolvedTargetWindow = reason == .selection ? targetWindow : nil
        if let resolvedTargetWindow {
            prepareActivation(resolvedTargetWindow)
        }
        focusSession.pendingDismissReason = reason
        focusSession.pendingFocusTargetWindow = resolvedTargetWindow
        focusSession.pendingPostCloseHandoffValidity = focusSession.currentPostCloseHandoffValidity()

        projection.settleRestFrames(targetWindow: resolvedTargetWindow)
        state = .closing(targetWindow: resolvedTargetWindow)
        updateWindowDisplays()

        if animated && motionPolicy.animationsEnabled {
            animator?.startCloseAnimation(
                targetWindow: resolvedTargetWindow,
                displayIds: windowSession.displayIds
            )
        } else {
            completeCloseTransition(targetWindow: resolvedTargetWindow)
        }
    }

    func commitOverviewPans() {
        guard let wmController else { return }
        let pans = projection.drainStripPans()
        guard !pans.isEmpty else { return }
        let affected = wmController.niriLayoutHandler.commitOverviewPans(pans)
        overviewSnapshot.refresh(affectedWorkspaceIds: affected, settledNiriFrames: true)
        projection.rebuildProjectedLayouts(revealingSelection: false)
    }

    func refreshCachedOverviewProjection(
        affectedWorkspaceIds: Set<WorkspaceDescriptor.ID>,
        selectedHandle: WindowHandle? = nil,
        settledNiriFrames: Bool = false,
        revealingSelection: Bool = true,
        preservingViewport: Bool = false,
        update: OverviewLayoutUpdate = .preserve
    ) {
        guard state.isOpen, let wmController else { return }
        environment.onCachedProjectionRefreshed(affectedWorkspaceIds)
        let workspaceManager = wmController.workspaceManager
        let selected = selectedHandle ?? projection.selectedWindowHandle
        let preservesViewport = preservingViewport && selected.map {
            overviewSnapshot.windows[$0]?.workspaceId == workspaceManager.workspace(for: $0.id)
        } == true
        let anchors = preservesViewport ? [:] : projection.captureSelectedViewportAnchors()
        let stripViewportOrigins = preservesViewport
            ? projection.captureStripViewportOrigins(in: affectedWorkspaceIds)
            : [:]

        overviewSnapshot.refresh(affectedWorkspaceIds: affectedWorkspaceIds, settledNiriFrames: settledNiriFrames)

        if let selectedHandle,
           overviewSnapshot.windows[selectedHandle] != nil,
           workspaceManager.entry(for: selectedHandle) != nil
        {
            projection.selectedWindowHandle = selectedHandle
        }
        projection.rebuildProjectedLayouts(
            preservingSelectedAnchors: anchors,
            preservingStripViewportOrigins: stripViewportOrigins,
            revealingSelection: revealingSelection && !preservesViewport
        )
        windowSession.updateWindowDisplays(state: state, update: update)
    }

    private func updateWindowDisplays(palette: OverviewRenderPalette? = nil) {
        windowSession.updateWindowDisplays(state: state, palette: palette)
    }

    private func updatePreviewVisibility() {
        let represented = Set(overviewSnapshot.windows.keys)
        switch state {
        case .closed:
            return
        case .closing:
            thumbnailCapture.reconcile(represented: represented, visible: [])
            return
        case .opening,
             .open:
            break
        }
        guard let wmController, !windowSession.displayIds.isEmpty else {
            thumbnailCapture.reconcile(represented: represented, visible: [])
            return
        }
        let screens = NSScreen.screens
        let projections: [OverviewPreviewProjection] = wmController.workspaceManager.monitors.compactMap { monitor in
            guard let layout = projection.layoutsByMonitor[monitor.id] else { return nil }
            return OverviewPreviewProjection(
                layout: layout,
                viewportFrame: OverviewLayoutCalculator.viewportFrame(for: monitor.frame),
                backingScaleFactor: screens.first(where: { $0.displayId == monitor.displayId })?.backingScaleFactor ?? 1
            )
        }
        var requests = OverviewThumbnailSizing.captureRequests(projections: projections)
        if let request = windowSession.dragPreviewRequest, represented.contains(request.handle) {
            requests.append(request)
        }
        thumbnailCapture.reconcile(represented: represented, visible: requests, prioritizing: selectedWindowHandle)
    }

    func onAnimationComplete(state: OverviewState) {
        self.state = state
        updateWindowDisplays()
    }

    func completeCloseTransition(targetWindow: WindowHandle?) {
        guard state.isOpen else { return }
        let rememberedZoom = Double(projection.scale)
        focusSession.completeCloseTransition(targetWindow: targetWindow) {
            animator?.settle(at: 0)
            state = .closed
            if let settings = wmController?.settings.overview,
               abs(settings.zoom - rememberedZoom) > Double(OverviewViewportProjection.zoomEpsilon)
            {
                settings.zoom = rememberedZoom
            }
            cleanup()
            endOwnedSession()
            updateWindowDisplays()
        }
        wmController?.layoutRefreshController.collectUnusedWorkspacesIfIdle()
    }

    func handleManagedWindowRemoved(_ entry: WindowState) {
        guard state.isOpen else { return }
        guard let removedHandle = overviewSnapshot.windows.first(where: { $0.value.token == entry.token })?.key else {
            return
        }
        if drag.draggedHandle === removedHandle { drag.cancelDrag() }
        thumbnailCapture.remove(handle: removedHandle)
        let visibleOrder = projection.canonicalLayout()?.allWindows
            .filter(\.matchesSearch)
            .map(\.handle) ?? []
        guard overviewSnapshot.remove(removedHandle) != nil else { return }

        var nextSelection = projection.selectedWindowHandle
        if projection.selectedWindowHandle == removedHandle {
            nextSelection = OverviewNavigation.selectionAfterRemoving(
                removedHandle,
                from: visibleOrder,
                availableHandles: Set(overviewSnapshot.windows.keys)
            )
            projection.selectedWindowHandle = nextSelection
        }
        if focusSession.pendingFocusTargetWindow == removedHandle {
            focusSession.pendingFocusTargetWindow = nextSelection
        }

        refreshCachedOverviewProjection(
            affectedWorkspaceIds: [entry.workspaceId],
            selectedHandle: nextSelection
        )
    }

    func beginOwnedSession() {
        focusSession.capturePreviousFrontmostApplication()
        inputSession.start(
            inputHandler: input,
            onResignActive: { [weak self] in self?.handleApplicationDidResignActive() },
            onDisplayChange: { [weak self] in self?.completeCloseTransition(targetWindow: nil) }
        )
        focusSession.pendingDismissReason = .cancel
        focusSession.pendingFocusTargetWindow = nil
        focusSession.pendingPostCloseHandoffValidity = nil
    }

    func activateOwnedSession() {
        environment.activateOmniWM()
    }

    func handleApplicationDidResignActive() {
        guard state.isOpen else { return }
        dismiss(reason: .externalDeactivation, animated: true)
    }

    private func cleanup() {
        thumbnailCapture.clear()
        wallpaperCache.clear()
        input.reset()
        projection.searchQuery = ""
        projection.scale = 1.0
        projection.selectedWindowHandle = nil
        projection.activeInteractionMonitorId = nil
        overviewSnapshot.reset()
        projection.resetLayouts()
        drag.reset()
        mutationSession.reset()
        windowSession.closeWindows()
    }

    private func endOwnedSession() {
        inputSession.stop()
        focusSession.previousFrontmostApplicationPID = nil
        focusSession.pendingDismissReason = .cancel
        focusSession.pendingFocusTargetWindow = nil
        focusSession.pendingPostCloseHandoffValidity = nil
    }

    var hasActiveDragSession: Bool {
        drag.isActive
    }
}
