// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

extension AXManager {
    func applyFramesParallel(
        _ frames: [AXFrameApplicationTarget],
        terminalObserver: FrameApplicationTerminalObserver? = nil,
        verify: Bool = true
    ) {
        let writable = framesAllowedToWrite(frames)
        guard !writable.isEmpty else { return }
        applyWritableFramesParallel(
            writable,
            terminalObserver: terminalObserver,
            verify: verify
        )
    }

    func applyWritableFramesParallel(
        _ writable: [AXFrameApplicationTarget],
        terminalObserver: FrameApplicationTerminalObserver? = nil,
        verify: Bool
    ) {
        enqueueFrameApplications(
            writable,
            isRetry: false,
            verify: verify,
            terminalObserver: terminalObserver
        )
    }

    func applyClosingFrames(_ frames: [AXClosingFrameTarget]) {
        guard !frames.isEmpty else { return }
        var framesByPID: [pid_t: [AXClosingFrameTarget]] = [:]
        framesByPID.reserveCapacity(min(frames.count, 8))

        for frame in frames where !macOSHiddenAppPIDs.contains(frame.pid)
            && !isWindowNativeSuppressed(WindowToken(pid: frame.pid, windowId: frame.windowId))
        {
            framesByPID[frame.pid, default: []].append(frame)
        }

        for (pid, appFrames) in framesByPID {
            AppAXContextRegistry.contexts[pid]?.setClosingFramesBatch(appFrames)
        }
    }

    func applyParkFramesParallel(_ frames: [AXFrameApplicationTarget], afterFrameWritesOf windowIds: Set<Int> = []) {
        let writable = framesAllowedToWrite(frames)
        guard !writable.isEmpty else { return }
        let requests = parkLedger.prepareParkFrameApplications(
            writable,
            currentFrame: frameLedger.lastAppliedFrame
        )
        let awaitedWindowIds = windowIds.filter(isAwaitingFrameWrite)
        guard !awaitedWindowIds.isEmpty else {
            dispatchParkFrameApplications(requests)
            return
        }
        deferredParkRequests += requests
        deferredParkAwaitedWindowIds.formUnion(awaitedWindowIds)
        if deferredParkTimeout == nil {
            deferredParkTimeout = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                self?.releaseDeferredParkFrames(force: true)
            }
        }
    }

    func releaseDeferredParkFrames(force: Bool = false) {
        deferredParkAwaitedWindowIds = deferredParkAwaitedWindowIds.filter(isAwaitingFrameWrite)
        guard force || deferredParkAwaitedWindowIds.isEmpty else { return }
        let requests = deferredParkRequests.filter {
            parkLedger.pendingParkFrameRequest(for: $0.windowId)?.requestId == $0.requestId
        }
        deferredParkRequests = []
        deferredParkAwaitedWindowIds = []
        deferredParkTimeout?.cancel()
        deferredParkTimeout = nil
        dispatchParkFrameApplications(requests)
    }

    private func framesAllowedToWrite(
        _ frames: [AXFrameApplicationTarget]
    ) -> [AXFrameApplicationTarget] {
        guard needsFrameWriteFiltering
        else { return frames }
        return frames.filter {
            let allowed = isFrameAllowedToWrite($0)
            if !allowed { rejectInWorkspaceFrameSettlements($0) }
            return allowed
        }
    }

    private func isFrameAllowedToWrite(_ target: AXFrameApplicationTarget) -> Bool {
        !macOSHiddenAppPIDs.contains(target.pid)
            && !isWindowNativeSuppressed(WindowToken(pid: target.pid, windowId: target.windowId))
            && !excludeFrameWriteForNativeTitleBarDrag(
                pid: target.pid,
                windowId: target.windowId
            )
    }

    func handleParkFrameApplyResults(_ results: [AXFrameApplyResult]) {
        for result in results {
            FrameApplyTrace.recordResult(result, lane: .park)
        }
        dispatchParkFrameApplications(parkLedger.processParkFrameApplyResults(results))
    }

    private func dispatchParkFrameApplications(_ requests: [AXFrameApplicationRequest]) {
        guard !requests.isEmpty else { return }
        var requestsByPID: [pid_t: [AXFrameApplicationRequest]] = [:]
        requestsByPID.reserveCapacity(min(requests.count, 8))
        for request in requests {
            requestsByPID[request.pid, default: []].append(request)
        }

        for (pid, appFrames) in requestsByPID {
            guard let context = AppAXContextRegistry.contexts[pid] else {
                handleParkFrameApplyResults(
                    appFrames.map {
                        AXFrameApplyResult(
                            requestId: $0.requestId,
                            pid: $0.pid,
                            windowId: $0.windowId,
                            expectedWindow: $0.expectedWindow,
                            targetFrame: $0.frame,
                            currentFrameHint: $0.currentFrameHint,
                            writeResult: .skipped(
                                targetFrame: $0.frame,
                                currentFrameHint: $0.currentFrameHint,
                                failureReason: .contextUnavailable
                            ),
                            traceRequestId: $0.traceRequestId
                        )
                    }
                )
                continue
            }
            context.setParkFramesBatch(appFrames) { [weak self] results in
                self?.handleParkFrameApplyResults(results)
            }
        }
    }
}
