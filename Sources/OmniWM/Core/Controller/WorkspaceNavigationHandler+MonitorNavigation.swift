// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import OmniWMIPC

extension WorkspaceNavigationHandler {
    func focusMonitorCyclic(previous: Bool) {
        guard let controller else { return }
        guard let currentMonitorId = interactionMonitorId(for: controller)
        else { return }

        let targetMonitor: Monitor? = if previous {
            controller.workspaceManager.previousMonitor(from: currentMonitorId)
        } else {
            controller.workspaceManager.nextMonitor(from: currentMonitorId)
        }

        guard let target = targetMonitor else { return }
        switchToMonitor(target.id, fromMonitor: currentMonitorId)
    }

    func focusLastMonitor() {
        guard let controller else { return }
        guard let previousId = controller.workspaceManager.previousInteractionMonitorId else { return }
        guard let currentMonitorId = interactionMonitorId(for: controller)
        else { return }

        guard controller.workspaceManager.monitors.contains(where: { $0.id == previousId }) else { return }

        switchToMonitor(previousId, fromMonitor: currentMonitorId)
    }

    @discardableResult
    func focusMonitor(direction: Direction) -> Bool {
        guard let controller else { return false }
        guard let currentMonitorId = interactionMonitorId(for: controller) else { return false }
        guard let target = controller.workspaceManager.adjacentMonitor(
            from: currentMonitorId,
            direction: direction
        ) else { return false }
        guard let targetWorkspace = controller.workspaceManager.activeWorkspaceOrFirst(on: target.id)
        else { return false }

        let sourceFrame = controller.workspaceManager.selectedManagedToken
            .flatMap { controller.preferredKeyboardFocusFrame(for: $0) }
        let dwindleEngine = controller.workspaceManager.activeLayoutKind(for: targetWorkspace.id) == .dwindle
            ? controller.dwindleEngine
            : nil
        let candidates = controller.workspaceManager.tiledEntries(in: targetWorkspace.id)
            .lazy
            .compactMap { entry -> (token: WindowToken, frame: CGRect)? in
                if controller.isManagedWindowSuppressedByMacOS(entry.token)
                    || dwindleEngine?.isInactiveGroupMember(entry.token, in: targetWorkspace.id) == true
                {
                    return nil
                }
                return controller.preferredKeyboardFocusFrame(for: entry.token).map {
                    (token: entry.token, frame: $0)
                }
            }
        guard let chosen = Self.spatialNeighborToken(
            from: sourceFrame,
            candidates: candidates,
            direction: direction,
            targetFrame: controller.insetWorkingFrame(for: target)
        ) else { return false }
        _ = controller.workspaceManager.rememberFocus(chosen, in: targetWorkspace.id)
        return switchToMonitor(target.id, fromMonitor: currentMonitorId)
    }

    static func spatialNeighborToken<Candidates: Sequence>(
        from sourceFrame: CGRect?,
        candidates: Candidates,
        direction: Direction,
        targetFrame: @autoclosure () -> CGRect
    ) -> WindowToken? where Candidates.Element == (token: WindowToken, frame: CGRect) {
        var iterator = candidates.makeIterator()
        guard var chosen = iterator.next() else { return nil }
        let targetFrame = targetFrame()

        func crossOverlaps(_ frame: CGRect) -> Bool {
            guard let sourceFrame else { return true }
            switch direction {
            case .left,
                 .right:
                return frame.maxY > sourceFrame.minY && frame.minY < sourceFrame.maxY
            case .up,
                 .down:
                return frame.maxX > sourceFrame.minX && frame.minX < sourceFrame.maxX
            }
        }
        func edgeDistance(_ frame: CGRect) -> CGFloat {
            switch direction {
            case .left: targetFrame.maxX - frame.maxX
            case .right: frame.minX - targetFrame.minX
            case .up: frame.minY - targetFrame.minY
            case .down: targetFrame.maxY - frame.maxY
            }
        }
        func crossCenter(_ frame: CGRect) -> CGFloat {
            switch direction {
            case .left,
                 .right: frame.midY
            case .up,
                 .down: frame.midX
            }
        }

        let anchor = sourceFrame.map(crossCenter) ?? crossCenter(targetFrame)
        func outranks(_ lhs: Candidates.Element, _ rhs: Candidates.Element) -> Bool {
            let lhsOverlap = crossOverlaps(lhs.frame) ? 0 : 1
            let rhsOverlap = crossOverlaps(rhs.frame) ? 0 : 1
            if lhsOverlap != rhsOverlap { return lhsOverlap < rhsOverlap }
            let lhsEdge = edgeDistance(lhs.frame)
            let rhsEdge = edgeDistance(rhs.frame)
            if lhsEdge != rhsEdge { return lhsEdge < rhsEdge }
            return abs(crossCenter(lhs.frame) - anchor) < abs(crossCenter(rhs.frame) - anchor)
        }
        while let candidate = iterator.next() {
            if outranks(candidate, chosen) { chosen = candidate }
        }
        return chosen.token
    }

    @discardableResult
    private func switchToMonitor(
        _ targetMonitorId: Monitor.ID,
        fromMonitor currentMonitorId: Monitor.ID
    ) -> Bool {
        guard let controller, targetMonitorId != currentMonitorId else { return false }

        guard let targetWorkspace = controller.workspaceManager.activeWorkspaceOrFirst(on: targetMonitorId)
        else {
            return false
        }

        _ = controller.workspaceManager.setInteractionMonitor(targetMonitorId)
        let focusToken = controller.resolveAndSetWorkspaceFocusToken(for: targetWorkspace.id)

        controller.layoutRefreshController.commitWorkspaceTransition(
            affectedWorkspaces: [targetWorkspace.id],
            reason: .workspaceTransition
        ) { [weak controller] in
            if let focusToken {
                controller?.focusWindow(focusToken)
            }
        }
        return true
    }
}
