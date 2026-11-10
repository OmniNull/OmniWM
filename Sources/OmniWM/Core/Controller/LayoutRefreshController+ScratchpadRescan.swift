// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import QuartzCore

extension LayoutRefreshController {
    private enum ScratchpadRescanEvidence {
        case visibleFrame
        case windowServer
        case pinnedAX
    }

    private struct ScratchpadRescanObservation {
        let evidence: ScratchpadRescanEvidence
        let visibleFrame: CGRect?
    }

    func preserveScratchpadHiddenWindowsDuringFullRescan(
        _ entries: [WindowState],
        windowServerInfoByWindowId: [Int: WindowServerInfo],
        seenKeys: inout Set<WindowToken>,
        hasPinnedAXElement: (UInt32) -> Bool = { AXWindowService.hasPinnedAXElement(for: $0) }
    ) {
        guard let controller else { return }
        for entry in entries where controller.workspaceManager.hiddenState(for: entry.token)?.isScratchpad == true {
            if controller.workspaceManager.isAppHidden(pid: entry.pid) {
                seenKeys.insert(entry.token)
                continue
            }
            let observation = scratchpadRescanObservation(
                for: entry,
                windowServerInfo: windowServerInfoByWindowId[entry.windowId],
                hasPinnedAXElement: hasPinnedAXElement
            )
            switch observation?.evidence {
            case .visibleFrame:
                if pendingRevealTransaction(for: entry.windowId)?.token == entry.token,
                   let visibleFrame = observation?.visibleFrame
                {
                    finalizePendingRevealTransactionSuccess(
                        forWindowId: entry.windowId,
                        confirmedFrame: visibleFrame
                    )
                } else {
                    if controller.axManager.pendingParkWindowIds.contains(entry.windowId) {
                        seenKeys.insert(entry.token)
                        continue
                    }
                    cancelPendingScratchpadReveal(for: entry.token)
                    controller.workspaceManager.setHiddenState(nil, for: entry.token)
                    controller.axManager.unsuppressFrameWrites([(entry.pid, entry.windowId)])
                }
                seenKeys.insert(entry.token)
            case .windowServer,
                 .pinnedAX:
                seenKeys.insert(entry.token)
            case nil:
                break
            }
        }
    }

    private func scratchpadRescanObservation(
        for entry: WindowState,
        windowServerInfo: WindowServerInfo?,
        hasPinnedAXElement: (UInt32) -> Bool
    ) -> ScratchpadRescanObservation? {
        guard controller != nil else { return nil }
        guard let windowId = UInt32(exactly: entry.windowId) else { return nil }

        if let windowInfo = windowServerInfo {
            guard windowInfo.pid == entry.pid else { return nil }
            if let visibleFrame = scratchpadVisibleWindowServerFrame(windowInfo.frame, for: entry) {
                return ScratchpadRescanObservation(evidence: .visibleFrame, visibleFrame: visibleFrame)
            }
            return ScratchpadRescanObservation(evidence: .windowServer, visibleFrame: nil)
        }

        if hasPinnedAXElement(windowId) {
            return ScratchpadRescanObservation(evidence: .pinnedAX, visibleFrame: nil)
        }

        return nil
    }

    private func scratchpadVisibleWindowServerFrame(_ frame: CGRect, for entry: WindowState) -> CGRect? {
        let appKitFrame = ScreenCoordinateSpace.toAppKit(rect: frame)
        return scratchpadFrameIsVisible(appKitFrame, for: entry) ? appKitFrame : nil
    }

    private func scratchpadFrameIsVisible(_ frame: CGRect, for entry: WindowState) -> Bool {
        guard let controller else { return false }
        if let floatingFrame = controller.workspaceManager.floatingState(for: entry.token)?.lastFrame,
           frame.approximatelyEqual(to: floatingFrame, tolerance: FrameTolerance.screenMatch)
        {
            return true
        }
        return controller.workspaceManager.monitors.contains { monitor in
            frame.intersects(monitor.visibleFrame)
                && monitor.visibleFrame.contains(CGPoint(x: frame.midX, y: frame.midY))
        }
    }
}

extension LayoutRefreshController {
    func discardScratchpadRevealGroupAndReconcile(_ groupId: UInt64) {
        guard let index = revealGroups.discard(groupId) else { return }
        reconcileRevealedScratchpadAfterGroupDiscard(index)
    }

    func reconcileRevealedScratchpadAfterGroupDiscard(_ index: ScratchpadIndex) {
        guard let controller,
              controller.workspaceManager.revealedScratchpadIndex() == index,
              !controller.workspaceManager.scratchpadMembers(in: index).contains(where: {
                  controller.isManagedWindowDisplayable($0)
              })
        else {
            return
        }
        controller.workspaceManager.setRevealedScratchpad(nil)
        controller.requestWorkspaceBarRefresh()
    }
}
