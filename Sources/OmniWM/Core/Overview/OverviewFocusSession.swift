// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Carbon
import Foundation
import QuartzCore

@MainActor
final class OverviewFocusSession {
    private weak var wmController: WMController?
    private weak var overview: OverviewController?
    private let environment: OverviewEnvironment
    private let projection: OverviewViewportProjection
    private let overviewSnapshot: OverviewSnapshot
    private var state: OverviewState {
        overview?.state ?? .closed
    }

    private enum PostCloseHandoff {
        case activateApplication(pid_t)
        case focusWindow(WindowHandle)
    }

    struct PostCloseHandoffValidity: Equatable {
        let intentIssuanceWatermark: IntentID
        let selectedManagedToken: WindowToken?
        let nativeFocusOwner: NativeFocusOwner
        let pendingFocusedToken: WindowToken?
    }

    var previousFrontmostApplicationPID: pid_t?
    var pendingDismissReason: OverviewController.OverviewDismissReason = .cancel
    var pendingFocusTargetWindow: WindowHandle?
    var pendingPostCloseHandoffValidity: PostCloseHandoffValidity?
    private var postCloseHandoffGeneration: UInt64 = 0

    init(
        wmController: WMController,
        environment: OverviewEnvironment,
        projection: OverviewViewportProjection,
        snapshot: OverviewSnapshot
    ) {
        self.wmController = wmController
        self.environment = environment
        self.projection = projection
        overviewSnapshot = snapshot
    }

    func connect(overview: OverviewController) {
        self.overview = overview
    }

    func completeCloseTransition(targetWindow: WindowHandle?, close: () -> Void) {
        let dismissReason = pendingDismissReason
        let previousFrontmostApplicationPID = previousFrontmostApplicationPID
        let requestedTargetWindow = pendingFocusTargetWindow ?? targetWindow
        let handoffValidity = pendingPostCloseHandoffValidity ?? currentPostCloseHandoffValidity()
        let resolvedTargetWindow = requestedTargetWindow.flatMap { handle in
            wmController?.workspaceManager.handle(for: handle.id) === handle ? handle : nil
        }
        let handoff: PostCloseHandoff?
        if dismissReason.shouldRestorePreviousApplication
            || dismissReason == .selection && resolvedTargetWindow == nil,
            let previousFrontmostApplicationPID
        {
            handoff = .activateApplication(previousFrontmostApplicationPID)
        } else if dismissReason == .selection,
                  let resolvedTargetWindow
        {
            handoff = .focusWindow(resolvedTargetWindow)
        } else {
            handoff = nil
        }
        let handoffGeneration = advancePostCloseHandoffGeneration()

        close()

        if let handoff, let handoffValidity {
            schedulePostCloseHandoff(
                handoff,
                validity: handoffValidity,
                generation: handoffGeneration
            )
        }
    }

    @discardableResult
    func advancePostCloseHandoffGeneration() -> UInt64 {
        postCloseHandoffGeneration &+= 1
        return postCloseHandoffGeneration
    }

    func currentPostCloseHandoffValidity() -> PostCloseHandoffValidity? {
        guard let wmController else { return nil }
        return PostCloseHandoffValidity(
            intentIssuanceWatermark: wmController.intentLedger.issuanceWatermark(),
            selectedManagedToken: wmController.workspaceManager.selectedManagedToken,
            nativeFocusOwner: wmController.workspaceManager.nativeFocusOwner,
            pendingFocusedToken: wmController.workspaceManager.pendingFocusedToken
        )
    }

    private func schedulePostCloseHandoff(
        _ handoff: PostCloseHandoff,
        validity: PostCloseHandoffValidity,
        generation: UInt64
    ) {
        guard let wmController else { return }
        environment.schedulePostCloseHandoff { [weak self, weak wmController] in
            guard let self,
                  let overview = self.overview,
                  let wmController,
                  self.postCloseHandoffGeneration == generation,
                  case .closed = self.state,
                  self.currentPostCloseHandoffValidity() == validity
            else {
                return
            }

            switch handoff {
            case let .activateApplication(pid):
                self.environment.activateApplication(pid)
            case let .focusWindow(handle):
                guard wmController.workspaceManager.handle(for: handle.id) === handle else { return }
                overview.focusTargetWindow(handle)
            }
        }
    }

    func capturePreviousFrontmostApplication() {
        guard let frontmostPID = environment.frontmostApplicationPID(),
              frontmostPID != environment.currentProcessID()
        else {
            previousFrontmostApplicationPID = nil
            return
        }

        previousFrontmostApplicationPID = frontmostPID
    }
}
