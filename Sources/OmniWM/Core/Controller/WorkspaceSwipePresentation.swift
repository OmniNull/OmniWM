// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

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
        let inputSign: Double
        let visualSign: CGFloat
        let motion: WorkspaceSwipeMotion
        var progress = 0.0
        var phase = Phase.tracking
        var committing: Bool {
            phase == .committing || phase == .waitingForPlacement
        }

        var settlement: AXFrameSettlement?

        init(
            preparation: Preparation,
            destination: Workspace,
            cumulative: Double,
            isNext: Bool,
            timestamp: TimeInterval,
            recognitionMovement: SwipeEvent?
        ) {
            self.preparation = preparation
            self.destination = destination
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
            preparation.frame.height * 1.1
        }

        func offset(destination: Bool) -> CGVector {
            let translation = (CGFloat(progress) - (destination ? 1 : 0)) * stride * visualSign
            return CGVector(dx: 0, dy: translation)
        }
    }

    weak var refreshController: LayoutRefreshController?
    var preparation: Preparation?
    private(set) var flight: Flight?
    private var preview: WorkspaceSwipePreview?
    private let mediaTimeProvider: () -> TimeInterval

    init(
        refreshController: LayoutRefreshController,
        previewSurface: WorkspaceSwipePreview? = nil,
        mediaTimeProvider: @escaping () -> TimeInterval = CACurrentMediaTime
    ) {
        self.refreshController = refreshController
        preview = previewSurface
        self.mediaTimeProvider = mediaTimeProvider
    }

    var controller: WMController? {
        refreshController?.controller
    }

    var hasPresentation: Bool {
        flight != nil
    }

    func hasDisplayWork(_ displayId: CGDirectDisplayID) -> Bool {
        flight?.preparation.monitor.displayId == displayId && flight?.committing == false
            && flight?.motion.target != nil
    }

    func prepare(monitorId: Monitor.ID, timestamp: TimeInterval) -> Bool {
        guard let controller, controller.motionPolicy.animationsEnabled else { return false }
        let mediaTime = mediaTimeProvider()
        if let flight, flight.preparation.monitor.id == monitorId, !flight.committing,
           flight.motion.target != nil, flight.motion.catchMotion(
               cumulativeUnits: 0, timestamp: timestamp, animationTime: mediaTime
           )
        {
            flight.progress = flight.motion.progress(at: mediaTime)
            flight.phase = .tracking
            trace("caught", progress: flight.progress)
            return true
        }
        if flight != nil { cancel(reason: "new-contact") }
        preparation = nil
        guard let preparation = makePreparation(monitorId: monitorId) else {
            stopPreparing()
            trace("fallback-geometry")
            return false
        }
        self.preparation = preparation
        previewSurface(controller).warm(
            source: preparation.source.items,
            destination: (preparation.previous?.items ?? []) + (preparation.next?.items ?? []),
            monitor: preparation.monitor, workingFrame: preparation.frame
        )
        return false
    }

    func begin(
        axis: WorkspaceSwipeAxis, cumulative: Double, timestamp: TimeInterval,
        recognitionMovement: SwipeEvent? = nil
    ) {
        guard let controller, let preparation,
              controller.motionPolicy.animationsEnabled,
              let isNext = TrackpadGestureIntent.isNextWorkspace(
                  axis: axis, displacement: cumulative, naturalDirection: controller.settings.gestures.invertDirection
              ),
              let destination = isNext ? preparation.next : preparation.previous,
              destination.id != preparation.source.id
        else { return }
        let flight = Flight(
            preparation: preparation,
            destination: destination,
            cumulative: cumulative,
            isNext: isNext,
            timestamp: timestamp,
            recognitionMovement: recognitionMovement
        )
        guard participantsAreCurrent(flight) else {
            trace("fallback-participants")
            return
        }
        guard preview?.begin(
            source: preparation.source.items,
            destination: destination.items,
            monitor: preparation.monitor,
            workingFrame: preparation.frame
        ) == true else {
            trace("fallback-preview-unavailable")
            return
        }
        preview?.prepare(
            source: preparation.source.items,
            destination: destination.items,
            monitor: preparation.monitor,
            workingFrame: preparation.frame
        )
        refreshController?.stopScrollAnimation(for: preparation.monitor.displayId)
        refreshController?.stopDwindleAnimation(for: preparation.monitor.displayId)
        self.flight = flight
        trace("began")
        controller.surfaceReconciler.reconcileNow()
        present(flight, at: mediaTimeProvider())
    }

    @discardableResult
    func update(cumulative: Double, timestamp: TimeInterval) -> Bool {
        guard let flight, !flight.committing, flight.motion.target == nil else { return false }
        guard participantsAreCurrent(flight), controller?.motionPolicy.animationsEnabled == true else {
            cancel(reason: "invalidated")
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
            cancel(reason: "invalid-release")
            return true
        }
        flight.phase = .settling
        if refreshController?
            .displayLinkActivationForTests?(flight.preparation.monitor.displayId) == true { return true }
        guard let link = refreshController?.getOrCreateDisplayLink(for: flight.preparation.monitor.displayId) else {
            cancel(reason: "display-link-unavailable")
            return true
        }
        link.add(to: .main, forMode: .common)
        return true
    }

    func tick(displayId: CGDirectDisplayID, timestamp: TimeInterval) {
        guard hasDisplayWork(displayId), let flight else { return }
        guard participantsAreCurrent(flight), controller?.motionPolicy.animationsEnabled == true else {
            cancel(reason: "invalidated")
            return
        }
        present(flight, at: timestamp)
        if flight.motion.isComplete(at: timestamp) {
            if flight.motion.target == 1 { commit(flight) } else { cancel(reason: "cancelled") }
        }
    }

    func stopPreparing(warm: Bool = false) {
        guard flight == nil else { return }
        preparation = nil
        preview?.stop()
        if warm {
            refreshController?.collectUnusedWorkspacesIfIdle()
            warmPreviews()
        }
    }

    func cancel(reason: String) {
        guard let flight else {
            stopPreparing()
            return
        }
        self.flight = nil
        flight.settlement?.onChange = nil
        if controller?.axManager.workspaceFrameSettlement === flight.settlement {
            controller?.axManager.workspaceFrameSettlement = nil
        }
        preview?.stop()
        preparation = nil
        trace(reason, progress: flight.progress)
        controller?.surfaceReconciler.noteWorldChanged()
        refreshController?.stopDisplayLinkIfIdle(for: flight.preparation.monitor.displayId)
        if reason == "completed" || reason == "placement-failed" || reason == "cancelled" {
            refreshController?.collectUnusedWorkspacesIfIdle()
            warmPreviews()
        }
    }

    func checkSettlement() {
        guard let flight, flight.committing, let settlement = flight.settlement, settlement.isSettled else { return }
        if settlement.tokens.contains(where: {
            refreshController?.hasPendingRevealTransaction(for: $0.windowId) == true
        }) { return }
        cancel(reason: settlement.failed ? "placement-failed" : "completed")
    }

    func didSubmitPlacement() {
        guard let flight, flight.committing else { return }
        flight.settlement?.seal()
    }

    private func commit(_ flight: Flight) {
        guard let controller, let refreshController,
              controller.workspaceManager.activeWorkspaceOrFirst(on: flight.preparation.monitor.id)?.id
              == flight.preparation.source.id
        else {
            cancel(reason: "superseded")
            return
        }
        flight.phase = .committing
        let settlement =
            AXFrameSettlement(tokens: Set(controller.workspaceManager.entries(in: flight.destination.id).map(\.token)))
        flight.settlement = settlement
        settlement.onChange = { [weak self] in self?.checkSettlement() }
        controller.axManager.workspaceFrameSettlement = settlement
        controller.workspaceNavigationHandler.saveNiriViewportState(for: flight.preparation.source.id)
        guard controller.workspaceManager.setActiveWorkspace(flight.destination.id, on: flight.preparation.monitor.id)
        else {
            flight.phase = .settling
            cancel(reason: "commit-failed")
            return
        }
        trace("committed", progress: flight.progress)
        controller.workspaceNavigationHandler.commitWorkspaceTransitionFocusHandoff(
            targetWorkspaceId: flight.destination.id, monitor: flight.preparation.monitor, startScrollAnimation: false,
            placementSubmitted: { [weak self, weak flight] in
                guard let self, let flight, self.flight === flight else { return }
                didSubmitPlacement()
            },
            placementInvalidated: { [weak self, weak flight] in
                guard let self, let flight, self.flight === flight else { return }
                cancel(reason: "placement-invalidated")
            }
        )
        flight.phase = .waitingForPlacement
        refreshController.stopDisplayLinkIfIdle(for: flight.preparation.monitor.displayId)
    }
}

extension WorkspaceSwipePresentation {
    func windowRemoved(_ token: WindowToken) {
        preview?.remove(token: token)
    }

    func syncAvailability() {
        guard let controller, preview != nil,
              !controller.motionPolicy.animationsEnabled || !controller.settings.gestures.workspaceSwipeEnabled
        else { return }
        cancel(reason: "disabled")
        preview?.release()
        preview = nil
    }

    func previewSurface(_ controller: WMController) -> WorkspaceSwipePreview {
        if let preview { return preview }
        let preview = WorkspaceSwipePreview(ownedWindowRegistry: controller.ownedWindowRegistry)
        self.preview = preview
        return preview
    }

    private func present(_ flight: Flight, at timestamp: TimeInterval) {
        flight.progress = flight.motion.progress(at: timestamp)
        preview?.update(
            sourceOffset: flight.offset(destination: false),
            destinationOffset: flight.offset(destination: true)
        )
    }

    func trace(_ action: String, progress: Double = 0) {
        guard TrackpadScrollTrace.shared.isActive else { return }
        TrackpadScrollTrace.record(.workspacePresentation(
            renderer: "preview",
            action: action,
            progress: progress,
            velocity: flight?.motion.velocity(at: mediaTimeProvider()),
            target: flight?.motion.target
        ))
    }
}
