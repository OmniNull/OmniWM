// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import QuartzCore

@MainActor
final class WorkspaceSwipePresentation {
    struct Workspace {
        let id: WorkspaceDescriptor.ID
        let items: [WorkspaceSwipePreview.Item]
    }

    struct Preparation {
        let monitor: Monitor
        let frame: CGRect
        let source: Workspace
        let previous: Workspace?
        let next: Workspace?
    }

    enum Phase {
        case tracking, settling, committing, waitingForPlacement
    }

    final class Flight {
        let preparation: Preparation
        let destination: Workspace
        let axis: WorkspaceSwipeAxis
        let inputSign: Double
        let visualSign: CGFloat
        let motion: WorkspaceSwipeMotion
        var progress = 0.0
        var phase = Phase.tracking
        var committing: Bool {
            phase == .committing || phase == .waitingForPlacement
        }

        var settlement: AXFrameSettlement?
        var handoff: Handoff?
        var carry: ((TimeInterval) -> CGVector?)?
        var carried = CGVector.zero
        var chained = false
        var serial = 0

        init(
            preparation: Preparation,
            destination: Workspace,
            axis: WorkspaceSwipeAxis,
            cumulative: Double,
            isNext: Bool,
            timestamp: TimeInterval,
            recognitionMovement: SwipeEvent?
        ) {
            self.preparation = preparation
            self.destination = destination
            self.axis = axis
            inputSign = cumulative < 0 ? -1 : 1
            visualSign = isNext ? 1 : -1
            motion = WorkspaceSwipeMotion(
                cumulativeUnits: abs(cumulative), timestamp: timestamp,
                recognitionMovement: recognitionMovement.map {
                    SwipeEvent(delta: $0.delta * (cumulative < 0 ? -1 : 1), timestamp: $0.timestamp)
                }
            )
        }

        var stride: CGFloat {
            (axis == .horizontal ? preparation.frame.width : preparation.frame.height) * 1.1
        }

        func offset(destination: Bool) -> CGVector {
            let own = vector((CGFloat(progress) - (destination ? 1 : 0)) * stride * visualSign)
            return CGVector(dx: own.dx + carried.dx, dy: own.dy + carried.dy)
        }

        func residual(at timestamp: TimeInterval) -> CGVector? {
            let inherited = carry?(timestamp)
            if inherited == nil { carry = nil }
            guard inherited != nil || !motion.isComplete(at: timestamp) else { return nil }
            let own = vector((CGFloat(motion.progress(at: timestamp)) - 1) * stride * visualSign)
            return CGVector(dx: own.dx + (inherited?.dx ?? 0), dy: own.dy + (inherited?.dy ?? 0))
        }

        private func vector(_ translation: CGFloat) -> CGVector {
            axis == .horizontal ? CGVector(dx: -translation, dy: 0) : CGVector(dx: 0, dy: translation)
        }
    }

    weak var refreshController: LayoutRefreshController?
    var preparation: Preparation?
    private(set) var flights: [Monitor.ID: Flight] = [:]
    private weak var gestureFlight: Flight?
    private var chainMonitorId: Monitor.ID?
    private var latestSerial = 0
    private var latestGestureMonitorId: Monitor.ID?
    private var focusOwed = false
    var previews: [Monitor.ID: WorkspaceSwipePreview] = [:]
    var unclaimedPreview: WorkspaceSwipePreview?
    let previewFactory: (@MainActor (WMController) -> WorkspaceSwipePreview)?
    let mediaTimeProvider: () -> TimeInterval
    var handoffWindowInfo: @MainActor (Set<UInt32>) async throws -> [UInt32: WindowServerInfo]? = {
        try await SkyLight.shared.queryWindowInfoDeferred(windowIds: $0)
    }

    var handoffSleep: @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    init(
        refreshController: LayoutRefreshController,
        previewSurface: WorkspaceSwipePreview? = nil,
        previewFactory: (@MainActor (WMController) -> WorkspaceSwipePreview)? = nil,
        mediaTimeProvider: @escaping () -> TimeInterval = CACurrentMediaTime
    ) {
        self.refreshController = refreshController
        unclaimedPreview = previewSurface
        self.previewFactory = previewFactory
        self.mediaTimeProvider = mediaTimeProvider
    }

    var controller: WMController? {
        refreshController?.controller
    }

    var flight: Flight? {
        gestureFlight.flatMap { isCurrent($0) ? $0 : nil }
    }

    var hasPresentation: Bool {
        !flights.isEmpty
    }

    func hasDisplayWork(_ displayId: CGDirectDisplayID) -> Bool {
        flights.values.contains { hasDisplayWork($0, displayId) }
    }

    private func hasDisplayWork(_ flight: Flight, _ displayId: CGDirectDisplayID) -> Bool {
        flight.preparation.monitor.displayId == displayId && !flight.committing
            && (flight.motion.target != nil || flight.carry != nil)
    }

    func prepare(monitorId: Monitor.ID, timestamp: TimeInterval) -> Bool {
        gestureFlight = nil
        guard let controller, controller.motionPolicy.animationsEnabled else { return false }
        let mediaTime = mediaTimeProvider()
        let existing = flights[monitorId]
        if let existing, existing.committing || existing.motion.target == 1 {
            chainMonitorId = monitorId
            return false
        }
        chainMonitorId = nil
        if let existing, !existing.committing,
           existing.motion.target != nil, existing.motion.catchMotion(
               cumulativeUnits: 0, timestamp: timestamp, animationTime: mediaTime
           )
        {
            existing.progress = existing.motion.progress(at: mediaTime)
            existing.phase = .tracking
            gestureFlight = existing
            trace("caught", progress: existing.progress)
            return true
        }
        if let existing { cancel(existing, reason: "new-contact") }
        preparation = nil
        guard let preparation = makePreparation(monitorId: monitorId) else {
            stopPreparing()
            trace("fallback-geometry")
            return false
        }
        self.preparation = preparation
        let surface = previewSurface(controller, for: monitorId)
        surface.captureSource(monitor: preparation.monitor, workingFrame: preparation.frame)
        surface.warm(
            source: preparation.source.items,
            destination: (preparation.previous?.items ?? []) + (preparation.next?.items ?? []),
            monitor: preparation.monitor, workingFrame: preparation.frame
        )
        return false
    }

    @discardableResult
    func begin(
        axis: WorkspaceSwipeAxis, cumulative: Double, timestamp: TimeInterval,
        recognitionMovement: SwipeEvent? = nil
    ) -> Bool {
        guard let controller, controller.motionPolicy.animationsEnabled else { return false }
        let (preparation, predecessor) = beginPreparation()
        guard let preparation,
              let isNext = TrackpadGestureIntent.isNextWorkspace(
                  axis: axis, displacement: cumulative, naturalDirection: controller.settings.gestures.invertDirection
              ),
              let destination = (isNext ? preparation.next : preparation.previous)
              ?? createdDestination(isNext: isNext, from: preparation),
              destination.id != preparation.source.id
        else {
            guard let predecessor else { return false }
            return refuseOrFallBack(from: predecessor, axis: axis, cumulative: cumulative)
        }
        let preview = previewSurface(controller, for: preparation.monitor.id)
        if let predecessor,
           let handled = handOff(from: predecessor, into: preparation, toward: destination, using: preview)
        {
            return handled
        }
        if self.preparation == nil {
            self.preparation = preparation
            preview.warm(
                source: preparation.source.items, destination: destination.items,
                monitor: preparation.monitor, workingFrame: preparation.frame
            )
        }
        let flight = Flight(
            preparation: preparation,
            destination: destination,
            axis: axis,
            cumulative: cumulative,
            isNext: isNext,
            timestamp: timestamp,
            recognitionMovement: recognitionMovement
        )
        guard participantsAreCurrent(flight) else {
            if predecessor != nil { preview.stop() }
            trace("fallback-participants")
            return false
        }
        guard predecessor != nil || show(preview, for: flight) else {
            trace("fallback-preview-unavailable")
            return false
        }
        install(flight, after: predecessor)
        controller.surfaceReconciler.reconcileNow()
        present(flight, at: mediaTimeProvider())
        return true
    }

    @discardableResult
    func update(cumulative: Double, timestamp: TimeInterval) -> Bool {
        guard let flight, !flight.committing, flight.motion.target == nil else { return false }
        guard participantsAreCurrent(flight), controller?.motionPolicy.animationsEnabled == true else {
            cancel(flight, reason: "invalidated")
            return true
        }
        flight.motion.update(cumulativeUnits: cumulative * flight.inputSign, timestamp: timestamp)
        present(flight, at: mediaTimeProvider())
        return true
    }

    @discardableResult
    func release(timestamp: TimeInterval, allowFlick: Bool) -> Bool {
        guard let flight, !flight.committing else { return false }
        guard flight.motion.release(
            timestamp: timestamp, allowFlick: allowFlick, animationTime: mediaTimeProvider(),
            motion: controller?.motionPolicy.snapshot() ?? .enabled
        ) else {
            cancel(flight, reason: "invalid-release")
            return true
        }
        flight.phase = .settling
        if !activateDisplayLink(for: flight) {
            cancel(flight, reason: "display-link-unavailable")
            return true
        }
        prefetchChainTargets(after: flight)
        return true
    }

    private func activateDisplayLink(for flight: Flight) -> Bool {
        if refreshController?
            .displayLinkActivationForTests?(flight.preparation.monitor.displayId) == true { return true }
        guard let link = refreshController?.getOrCreateDisplayLink(for: flight.preparation.monitor.displayId) else {
            return false
        }
        link.add(to: .main, forMode: .common)
        return true
    }

    func otherGestureRecognized(on monitorId: Monitor.ID) {
        noteNewestGesture(on: monitorId)
        guard chainMonitorId == nil else {
            chainMonitorId = nil
            return
        }
        cancel(reason: "other-gesture")
    }

    func noteSwitchWithoutPresentation(on monitorId: Monitor.ID) {
        noteNewestGesture(on: monitorId)
    }

    func forgetNewestGesture(onDisplay displayId: CGDirectDisplayID) {
        guard latestGestureMonitorId?.displayId == displayId else { return }
        let survivor = flights.values.max { $0.serial < $1.serial }
        latestGestureMonitorId = survivor?.preparation.monitor.id
        if let survivor { latestSerial = survivor.serial }
    }

    private func noteNewestGesture(on monitorId: Monitor.ID) {
        latestSerial += 1
        latestGestureMonitorId = monitorId
    }

    func tick(displayId: CGDirectDisplayID, timestamp: TimeInterval) {
        for flight in flights.values where hasDisplayWork(flight, displayId) {
            guard participantsAreCurrent(flight), controller?.motionPolicy.animationsEnabled == true else {
                cancel(flight, reason: "invalidated")
                continue
            }
            present(flight, at: timestamp)
            if flight.motion.isComplete(at: timestamp) {
                if flight.motion.target == 1 { commit(flight) } else { cancel(flight, reason: "cancelled") }
            }
        }
    }

    func stopPreparing(warm: Bool = false) {
        chainMonitorId = nil
        guard flight == nil else { return }
        preparation = nil
        for (monitorId, preview) in previews where flights[monitorId] == nil {
            preview.stop()
        }
        if warm {
            refreshController?.collectUnusedWorkspacesIfIdle()
            warmPreviews()
        }
    }
}

extension WorkspaceSwipePresentation {
    private func beginPreparation() -> (Preparation?, predecessor: Flight?) {
        guard let chainMonitorId else { return (preparation, nil) }
        self.chainMonitorId = nil
        if let existing = flights[chainMonitorId] {
            return (makePreparation(monitorId: chainMonitorId, chainedSource: existing.destination), existing)
        }
        return (preparation ?? makePreparation(monitorId: chainMonitorId), nil)
    }

    private func show(_ preview: WorkspaceSwipePreview, for flight: Flight) -> Bool {
        let preparation = flight.preparation
        guard preview.begin(
            source: preparation.source.items,
            destination: flight.destination.items,
            monitor: preparation.monitor,
            workingFrame: preparation.frame
        ) else { return false }
        preview.prepare(
            source: preparation.source.items,
            destination: flight.destination.items,
            monitor: preparation.monitor,
            workingFrame: preparation.frame
        )
        return true
    }

    private func install(_ flight: Flight, after predecessor: Flight?) {
        let monitor = flight.preparation.monitor
        refreshController?.stopScrollAnimation(for: monitor.displayId)
        refreshController?.stopDwindleAnimation(for: monitor.displayId)
        if let predecessor {
            flight.chained = true
            flight.carry = { predecessor.residual(at: $0) }
            _ = activateDisplayLink(for: flight)
        }
        noteNewestGesture(on: monitor.id)
        flight.serial = latestSerial
        flights[monitor.id] = flight
        gestureFlight = flight
        trace(predecessor == nil ? "began" : "chained")
    }

    func cancel(reason: String) {
        guard let flight else {
            stopPreparing()
            return
        }
        cancel(flight, reason: reason)
    }

    func cancelAll(reason: String) {
        focusOwed = false
        for flight in Array(flights.values) {
            cancel(flight, reason: reason, settlingFocus: false)
        }
        stopPreparing()
    }

    func cancel(_ flight: Flight, reason: String, keepingPreview: Bool = false, settlingFocus: Bool = true) {
        let monitorId = flight.preparation.monitor.id
        guard flights[monitorId] === flight else { return }
        flights[monitorId] = nil
        flight.handoff?.cancel()
        flight.settlement?.onChange = nil
        controller?.axManager.workspaceFrameSettlements.removeAll { $0 === flight.settlement }
        if !keepingPreview { previews[monitorId]?.stop() }
        if preparation?.monitor.id == monitorId { preparation = nil }
        trace(reason, progress: flight.progress)
        controller?.surfaceReconciler.noteWorldChanged()
        refreshController?.stopDisplayLinkIfIdle(for: flight.preparation.monitor.displayId)
        if settlingFocus, flight.serial == latestSerial, !flight.committing, reason != "chained",
           focusOwed || flights.values.contains(where: { $0.preparation.monitor.id != monitorId })
        {
            settleOwedFocus(on: flight.preparation.monitor)
        }
        if ["completed", "placement-failed", "handoff-unconfirmed", "cancelled"].contains(reason) {
            refreshController?.collectUnusedWorkspacesIfIdle()
            warmPreviews()
        }
    }

    func checkSettlement() {
        for flight in Array(flights.values) {
            guard flight.committing, let settlement = flight.settlement, settlement.isSettled else { continue }
            if settlement.tokens.contains(where: {
                refreshController?.hasPendingRevealTransaction(for: $0.windowId) == true
            }) { continue }
            confirmHandoff(flight)
        }
    }

    func didSubmitPlacement() {
        guard let flight else { return }
        didSubmitPlacement(flight)
    }

    private func didSubmitPlacement(_ flight: Flight) {
        guard isCurrent(flight), flight.committing else { return }
        flight.settlement?.seal()
    }

    func commit(_ flight: Flight) {
        let monitor = flight.preparation.monitor
        guard let controller, let refreshController,
              controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
              == flight.preparation.source.id
        else {
            cancel(flight, reason: "superseded")
            return
        }
        let takesFocus = flight.serial == latestSerial || latestGestureMonitorId == monitor.id
        flight.phase = .committing
        previews[monitor.id]?.freezeSource()
        let settlement =
            AXFrameSettlement(tokens: Set(controller.workspaceManager.entries(in: flight.destination.id).map(\.token)))
        flight.settlement = settlement
        settlement.onChange = { [weak self] in self?.checkSettlement() }
        controller.axManager.workspaceFrameSettlements.append(settlement)
        controller.workspaceNavigationHandler.saveNiriViewportState(for: flight.preparation.source.id)
        guard controller.workspaceManager.setActiveWorkspace(
            flight.destination.id, on: monitor.id, updateInteractionMonitor: takesFocus
        ) else {
            flight.phase = .settling
            cancel(flight, reason: "commit-failed")
            return
        }
        trace(takesFocus ? "committed" : "committed-background", progress: flight.progress)
        let placementSubmitted: LayoutRefreshController.PostLayoutAction = { [weak self, weak flight] in
            guard let self, let flight else { return }
            didSubmitPlacement(flight)
        }
        let placementInvalidated: LayoutRefreshController.PostLayoutAction = { [weak self, weak flight] in
            guard let self, let flight, isCurrent(flight) else { return }
            cancel(flight, reason: "placement-invalidated")
        }
        if takesFocus {
            focusOwed = false
            controller.workspaceNavigationHandler.commitWorkspaceTransitionFocusHandoff(
                targetWorkspaceId: flight.destination.id, monitor: monitor, startScrollAnimation: false,
                placementSubmitted: placementSubmitted, placementInvalidated: placementInvalidated
            )
        } else {
            focusOwed = flights.values.contains { $0.serial > flight.serial }
            refreshController.stopScrollAnimation(for: monitor.displayId)
            refreshController.commitWorkspaceTransition(
                postLayout: placementSubmitted, postLayoutInvalidated: placementInvalidated
            )
            if !focusOwed { keepFocusOffHiddenWorkspace(flight.preparation.source.id) }
        }
        flight.phase = .waitingForPlacement
        refreshController.stopDisplayLinkIfIdle(for: monitor.displayId)
    }

    private func keepFocusOffHiddenWorkspace(_ workspaceId: WorkspaceDescriptor.ID) {
        guard let controller, let monitorId = latestGestureMonitorId,
              let monitor = controller.workspaceManager.monitor(byId: monitorId),
              let token = controller.workspaceManager.nativeManagedFocusToken,
              controller.workspaceManager.entry(for: token)?.workspaceId == workspaceId
        else { return }
        settleOwedFocus(on: monitor)
    }

    private func settleOwedFocus(on monitor: Monitor) {
        focusOwed = false
        guard let controller, let workspace = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)
        else { return }
        trace("focus-owed")
        _ = controller.workspaceManager.setInteractionMonitor(monitor.id)
        controller.workspaceNavigationHandler.commitWorkspaceTransitionFocusHandoff(
            targetWorkspaceId: workspace.id, monitor: monitor, startScrollAnimation: false
        )
    }
}
