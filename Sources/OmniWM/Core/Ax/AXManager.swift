// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

@MainActor
final class AXManager {
    nonisolated static let perAppTimeout: TimeInterval = 0.5
    typealias FrameApplicationTerminalObserver = AXFrameApplicationTerminalObserver

    private var appTerminationObserver: NSObjectProtocol?
    private var appLaunchObserver: NSObjectProtocol?
    var onAppLaunched: ((NSRunningApplication) -> Void)?
    var isWindowParked: ((Int) -> Bool)?
    var onTerminalFrameRefusal: ((AXFrameTerminalRefusal) -> Void)?
    var onFrameApplyTerminated: ((AXFrameApplyResult) -> Void)?
    var onFrameApplySucceeded: ((AXFrameApplyResult) -> Void)?
    var onStableSizeClamp: ((AXFrameApplyResult) -> Void)?
    var onManagedWindowBindingFailed: ((pid_t) -> Void)? {
        get { managedWindowBindings.onManagedWindowBindingFailed }
        set { managedWindowBindings.onManagedWindowBindingFailed = newValue }
    }

    var managedWindowBindingRetryDelayProvider: (Int) -> Duration? {
        get { managedWindowBindings.managedWindowBindingRetryDelayProvider }
        set { managedWindowBindings.managedWindowBindingRetryDelayProvider = newValue }
    }

    var fullRescanWindowInfoProvider: @MainActor (Set<UInt32>) async throws -> [UInt32: WindowServerInfo]? = {
        try await SkyLight.shared.queryWindowInfoDeferred(windowIds: $0)
    }

    let frameBatchBuffer = AXFrameBatchBuffer()
    let managedWindowBindings = AXManagedWindowBindings()
    let frameLedger = AXFrameApplicationLedger()
    var workspaceFrameSettlement: AXFrameSettlement?
    private var pendingFrameRetryTasksByWindowId: [Int: Task<Void, Never>] = [:]
    private var pendingFrameRetryGenerationByWindowId: [Int: UInt64] = [:]
    private var pendingFrameRetryRequestsByWindowId: [Int: AXFrameRetryRequest] = [:]
    private var nextFrameRetryGeneration: UInt64 = 1
    private var nativeTitleBarDrag: (token: WindowToken, excludedFrameWrite: Bool)?
    /// Window IDs belonging to inactive workspaces — checked LIVE in applyFramesParallel.
    private(set) var inactiveWorkspaceWindowIds: Set<Int> = []
    private(set) var macOSHiddenAppPIDs: Set<pid_t> = []

    private var skyLightLivePositionByWindowId: [Int: CGPoint] = [:]

    let parkLedger = AXParkFrameLedger()

    var pendingParkWindowIds: Set<Int> {
        parkLedger.pendingParkWindowIds
    }

    var pendingParkWindowIdsAwaitingSkyLightMove: Set<Int> {
        parkLedger.pendingParkWindowIds.filter { skyLightLivePositionByWindowId[$0] == nil }
    }

    func prepareParkFrameApplications(_ frames: [AXFrameApplicationTarget]) -> [AXFrameApplicationRequest] {
        parkLedger.prepareParkFrameApplications(frames, currentFrame: frameLedger.lastAppliedFrame)
    }

    var needsFrameWriteFiltering: Bool {
        !macOSHiddenAppPIDs.isEmpty || !AppAXContextRegistry.minimizedWindowTokens.isEmpty || nativeTitleBarDrag != nil
    }

    func markAppHidden(_ pid: pid_t) {
        macOSHiddenAppPIDs.insert(pid)
    }

    func markAppShown(_ pid: pid_t) {
        macOSHiddenAppPIDs.remove(pid)
    }

    init() {
        installWorkspaceObservers()
    }

    func installWorkspaceObservers() {
        if appTerminationObserver == nil {
            setupTerminationObserver()
        }
        if appLaunchObserver == nil {
            setupLaunchObserver()
        }
    }

    private func setupTerminationObserver() {
        appTerminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            let pid = app.processIdentifier
            if WindowAdmissionTrace.shared.isActive, pid != getpid() {
                WindowAdmissionTrace.record(
                    .init(
                        action: .processTerminated,
                        pid: pid,
                        bundleId: app.bundleIdentifier
                    )
                )
            }
            EventIntake.post(
                .application(.terminated(
                    pid: pid,
                    frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier
                ))
            )
            Task { @MainActor in
                AppAXContextRegistry.clearMinimizedWindows(for: pid)
                self?.managedWindowBindings.clearManagedWindowBindingRetry(for: pid)
                self?.parkLedger.clearParkFrameState(for: pid, reason: "context-teardown")
                if let context = AppAXContextRegistry.contexts[pid] {
                    context.destroy()
                }
            }
        }
    }

    private func setupLaunchObserver() {
        appLaunchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            if WindowAdmissionTrace.shared.isActive, app.processIdentifier != getpid() {
                WindowAdmissionTrace.record(
                    .init(
                        action: .processLaunched,
                        pid: app.processIdentifier,
                        bundleId: app.bundleIdentifier
                    )
                )
            }
            Task { @MainActor in
                self?.onAppLaunched?(app)
            }
        }
    }

    func updateInactiveWorkspaceWindows(
        allEntries: [(workspaceId: WorkspaceDescriptor.ID, windowId: Int)],
        activeWorkspaceIds: Set<WorkspaceDescriptor.ID>,
        nativeInactiveWindowIds: Set<Int> = []
    ) {
        inactiveWorkspaceWindowIds.removeAll(keepingCapacity: true)
        inactiveWorkspaceWindowIds.reserveCapacity(nativeInactiveWindowIds.count + allEntries.count)
        inactiveWorkspaceWindowIds.formUnion(nativeInactiveWindowIds)
        for (wsId, windowId) in allEntries where !activeWorkspaceIds.contains(wsId) {
            inactiveWorkspaceWindowIds.insert(windowId)
        }
    }

    func markWindowActive(_ windowId: Int) {
        inactiveWorkspaceWindowIds.remove(windowId)
    }

    func markWindowInactive(_ windowId: Int) {
        inactiveWorkspaceWindowIds.insert(windowId)
    }

    func beginNativeTitleBarDrag(for token: WindowToken) {
        let hadPendingFrameWrite = frameLedger.hasPendingFrameWrite(for: token.windowId)
        nativeTitleBarDrag = (token: token, excludedFrameWrite: hadPendingFrameWrite)
        cancelPendingFrameJobs([(pid: token.pid, windowId: token.windowId)], reason: "native-drag-begin")
    }

    func endNativeTitleBarDrag(for token: WindowToken) -> Bool {
        guard nativeTitleBarDrag?.token == token else { return false }
        let excludedFrameWrite = nativeTitleBarDrag?.excludedFrameWrite == true
        nativeTitleBarDrag = nil
        return excludedFrameWrite
    }

    func isNativeTitleBarDragActive(for token: WindowToken) -> Bool {
        nativeTitleBarDrag?.token == token
    }

    func recordSkyLightMove(windowId: Int, origin: CGPoint) {
        skyLightLivePositionByWindowId[windowId] = origin
    }

    func skyLightLivePosition(for windowId: Int) -> CGPoint? {
        skyLightLivePositionByWindowId[windowId]
    }

    func clearSkyLightLivePosition(for windowId: Int) {
        skyLightLivePositionByWindowId.removeValue(forKey: windowId)
    }

    func frameStateDump() -> String {
        var sections = ["Ledger:\n\(frameLedger.stateDump())"]
        let inactive = inactiveWorkspaceWindowIds.sorted()
        let inactiveText = inactive.isEmpty ? "none" : inactive.map(String.init).joined(separator: ",")
        sections.append("inactiveWorkspaceWindows=\(inactiveText)")
        let retryTasks = pendingFrameRetryTasksByWindowId.keys.sorted()
        if !retryTasks.isEmpty {
            sections.append("pendingRetryTasks=" + retryTasks.map(String.init).joined(separator: ","))
        }
        if !pendingFrameRetryGenerationByWindowId.isEmpty {
            let generations = pendingFrameRetryGenerationByWindowId.sorted { $0.key < $1.key }
                .map { "\($0.key):\($0.value)" }
                .joined(separator: ",")
            sections.append("retryGenerations=" + generations)
        }
        return sections.joined(separator: "\n")
    }

    func clearInactiveWorkspaceWindows() {
        inactiveWorkspaceWindowIds.removeAll()
    }

    func resetFrameApplicationStateForRebind(
        oldWindowId: Int,
        newWindowId: Int,
        isIncarnationReplacement: Bool
    ) -> [AXFrameTerminalDelivery] {
        var deliveries = isIncarnationReplacement
            ? frameLedger.removeWindowState(windowId: oldWindowId)
            : frameLedger.cancelFrameJob(windowId: oldWindowId)
        cancelPendingFrameRetry(for: oldWindowId)
        if oldWindowId != newWindowId {
            cancelPendingFrameRetry(for: newWindowId)
            if isIncarnationReplacement {
                deliveries.append(contentsOf: frameLedger.removeWindowState(windowId: newWindowId))
            } else {
                frameLedger.rekeyWindowState(oldWindowId: oldWindowId, newWindowId: newWindowId)
            }
            rekeyAuxiliaryWindowState(from: oldWindowId, to: newWindowId)
        }
        if isIncarnationReplacement {
            parkLedger.resetIncarnationAuxiliaryState(oldWindowId: oldWindowId, newWindowId: newWindowId)
        }
        frameLedger.forceApplyNextFrame(for: newWindowId)
        clearSkyLightLivePosition(for: oldWindowId)
        clearSkyLightLivePosition(for: newWindowId)
        return deliveries
    }

    private func rekeyAuxiliaryWindowState(from oldWindowId: Int, to newWindowId: Int) {
        if inactiveWorkspaceWindowIds.remove(oldWindowId) != nil {
            inactiveWorkspaceWindowIds.insert(newWindowId)
        }
    }

    func removeWindowState(pid: pid_t, expectedWindow: AXWindowRef) {
        let windowId = expectedWindow.windowId
        AppAXContextRegistry.setWindowMinimized(false, token: WindowToken(pid: pid, windowId: windowId))
        if nativeTitleBarDrag?.token == WindowToken(pid: pid, windowId: windowId) {
            nativeTitleBarDrag = nil
        }
        parkLedger.cancelParkFrameJobs([(pid: pid, windowId: windowId)], reason: "removed")
        AppAXContextRegistry.contexts[pid]?.prepareWindowRemoval(for: windowId)
        let deliveries = takeRemovedWindowLedgerState(windowId: windowId)
        AppAXContextRegistry.contexts[pid]?.removeWindowState(expectedWindow: expectedWindow)
        for delivery in deliveries {
            delivery.deliver()
        }
    }

    func removeWindowLedgerState(pid: pid_t, windowId: Int) {
        AppAXContextRegistry.setWindowMinimized(false, token: WindowToken(pid: pid, windowId: windowId))
        if nativeTitleBarDrag?.token == WindowToken(pid: pid, windowId: windowId) {
            nativeTitleBarDrag = nil
        }
        parkLedger.cancelParkFrameJobs([(pid: pid, windowId: windowId)], reason: "removed")
        if let context = AppAXContextRegistry.contexts[pid] {
            context.prepareWindowRemoval(for: windowId)
            context.invalidateWindowIdentity()
        }
        let deliveries = takeRemovedWindowLedgerState(windowId: windowId)
        for delivery in deliveries {
            delivery.deliver()
        }
    }

    private func takeRemovedWindowLedgerState(windowId: Int) -> [AXFrameTerminalDelivery] {
        let deliveries = frameLedger.removeWindowState(windowId: windowId)
        cancelPendingFrameRetry(for: windowId)
        inactiveWorkspaceWindowIds.remove(windowId)
        clearSkyLightLivePosition(for: windowId)

        return deliveries
    }

    func destroyContextIfPresent(for pid: pid_t, reason: String) {
        guard let context = AppAXContextRegistry.contexts[pid] else { return }
        parkLedger.clearParkFrameState(for: pid, reason: reason)
        context.destroy()
    }

    func garbageCollectContexts() {
        for (pid, context) in Array(AppAXContextRegistry.contexts) where context.nsApp.isTerminated {
            AppAXContextRegistry.clearMinimizedWindows(for: pid)
            parkLedger.clearParkFrameState(for: pid, reason: "context-garbage-collected")
            context.destroy()
        }
    }

    func prepareForStopRestoration() {
        cancelAllPendingFrameState()
        for context in AppAXContextRegistry.contexts.values {
            context.prepareForStopRestoration()
        }
    }

    func cleanup(completion: (@MainActor @Sendable () -> Void)? = nil) {
        if let observer = appTerminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appTerminationObserver = nil
        }
        if let observer = appLaunchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appLaunchObserver = nil
        }

        cancelAllPendingFrameState()
        frameLedger.invalidateAllAppliedFrames()
        skyLightLivePositionByWindowId.removeAll(keepingCapacity: true)
        managedWindowBindings.shutdown()
        frameBatchBuffer.clear()

        AppAXContextRegistry.shutdownAll(completion: completion)
    }

    func excludeFrameWriteForNativeTitleBarDrag(pid: pid_t, windowId: Int) -> Bool {
        guard nativeTitleBarDrag?.token == WindowToken(pid: pid, windowId: windowId) else {
            return false
        }
        nativeTitleBarDrag?.excludedFrameWrite = true
        return true
    }
}

extension AXManager {
    func scheduleFrameRetry(_ retry: AXFrameRetryRequest) {
        let pid = retry.pid
        let windowId = retry.windowId
        let expectedWindow = retry.expectedWindow
        let frame = retry.frame
        cancelPendingFrameRetry(for: windowId)
        let generation = nextFrameRetryGeneration
        nextFrameRetryGeneration &+= 1
        pendingFrameRetryGenerationByWindowId[windowId] = generation
        pendingFrameRetryRequestsByWindowId[windowId] = retry
        pendingFrameRetryTasksByWindowId[windowId] = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            let currentWindowId = self.frameLedger.resolvedWindowId(for: windowId)
            guard self.pendingFrameRetryGenerationByWindowId[currentWindowId] == generation else { return }
            guard !self.frameLedger.hasPendingFrameWrite(for: currentWindowId) else { return }
            self.pendingFrameRetryGenerationByWindowId.removeValue(forKey: currentWindowId)
            self.pendingFrameRetryTasksByWindowId.removeValue(forKey: currentWindowId)
            self.pendingFrameRetryRequestsByWindowId.removeValue(forKey: currentWindowId)
            self.enqueueFrameApplications(
                [
                    AXFrameApplicationTarget(
                        pid: pid,
                        window: AXWindowRef(
                            element: expectedWindow.element,
                            windowId: currentWindowId
                        ),
                        frame: frame,
                        components: retry.components
                    )
                ],
                isRetry: true,
                parentTraceRequestId: retry.traceRequestId
            )
        }
    }

    @discardableResult
    func cancelPendingFrameRetry(for windowId: Int) -> AXFrameApplyResult? {
        let retry = pendingFrameRetryRequestsByWindowId.removeValue(forKey: windowId)
        pendingFrameRetryTasksByWindowId.removeValue(forKey: windowId)?.cancel()
        pendingFrameRetryGenerationByWindowId.removeValue(forKey: windowId)
        guard let retry else { return nil }
        let result = AXFrameApplyResult(
            requestId: retry.requestId,
            pid: retry.pid,
            windowId: retry.windowId,
            expectedWindow: retry.expectedWindow,
            targetFrame: retry.frame,
            currentFrameHint: retry.currentFrameHint,
            writeResult: .skipped(
                targetFrame: retry.frame,
                currentFrameHint: retry.currentFrameHint,
                failureReason: .cancelled,
                observedFrame: retry.currentFrameHint,
                components: retry.components
            ),
            traceRequestId: retry.traceRequestId
        )
        FrameApplyTrace.recordResult(result)
        return result
    }

    private func cancelAllPendingFrameState() {
        parkLedger.shutdown()

        let retryWindowIds = Set(pendingFrameRetryTasksByWindowId.keys)
            .union(pendingFrameRetryRequestsByWindowId.keys)
        for windowId in retryWindowIds {
            cancelPendingFrameRetry(for: windowId)
        }
        pendingFrameRetryTasksByWindowId.removeAll()
        pendingFrameRetryGenerationByWindowId.removeAll()
        pendingFrameRetryRequestsByWindowId.removeAll()
        macOSHiddenAppPIDs.removeAll()

        let deliveries = frameLedger.cancelAllPendingFrameState()
        for delivery in deliveries {
            delivery.deliver()
        }
    }
}
