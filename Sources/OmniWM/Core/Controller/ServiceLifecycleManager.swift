// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

enum ActivationEventSource: String, Sendable {
    case focusedWindowChanged
    case workspaceDidActivateApplication
    case workspaceDidUnhideApplication
    case cgsFrontAppChanged

    var isAuthoritative: Bool {
        self == .focusedWindowChanged
    }
}

@MainActor
final class ServiceLifecycleManager {
    weak var controller: WMController?
    let topologyInventory: NativeSpaceInventoryController
    var monitorConfiguration: MonitorConfigurationHandler

    private var workspaceObservation = WorkspaceEventObservation()
    private var screenParametersObserver: NSObjectProtocol?
    private var permissionCheckerTask: Task<Void, Never>?

    var userStopPhase = UserStopPhase.idle
    var quitRequested = false
    var stopCompletions: [@MainActor @Sendable () -> Void] = []
    var stopDeadlineTask: Task<Void, Never>?

    var isStoppingForUser: Bool {
        userStopPhase != .idle
    }

    init(controller: WMController) {
        self.controller = controller
        let topologyInventory = NativeSpaceInventoryController(controller: controller)
        self.topologyInventory = topologyInventory
        monitorConfiguration = MonitorConfigurationHandler(controller: controller, inventory: topologyInventory)
    }

    func start() {
        guard let controller, !isStoppingForUser, !quitRequested else { return }
        let initialPermissionGranted = AccessibilityPermissionMonitor.shared.isGranted
        controller.updateAccessibilityPermissionGranted(initialPermissionGranted)
        setupSeparateSpacesObserver()
        maybeStartServices()
        startPermissionMonitoring()
    }

    func restart() {
        stop()
        start()
    }

    private func startPermissionMonitoring() {
        permissionCheckerTask?.cancel()
        permissionCheckerTask = Task { @MainActor [weak self, weak controller] in
            guard let self else { return }
            for await granted in AccessibilityPermissionMonitor.shared.stream(initial: true) {
                guard let controller, !Task.isCancelled else { return }

                if granted {
                    controller.updateAccessibilityPermissionGranted(true)
                    self.maybeStartServices()
                } else {
                    _ = self.controller?.axManager.requestPermission() ?? false
                    controller.updateAccessibilityPermissionGranted(false)
                }
            }
        }
    }

    private func maybeStartServices() {
        guard let controller, !isStoppingForUser, !quitRequested else { return }
        controller.updateDisplaySpacesMode(SkyLight.shared.displaysHaveSeparateSpaces)
        if controller.displaySpacesMode == .disabled {
            if controller.hasStartedServices {
                stop()
                startPermissionMonitoring()
            }
            return
        }
        guard !controller.hasStartedServices,
              controller.desiredEnabled,
              AccessibilityPermissionMonitor.shared.isGranted
        else { return }
        startServices()
    }

    private func setupSeparateSpacesObserver() {
        guard screenParametersObserver == nil else { return }
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            ScreenCoordinateSpace.invalidateCache()
            Task { @MainActor in self?.maybeStartServices() }
        }
    }

    private func startServices() {
        guard let controller, !controller.hasStartedServices else { return }
        if monitorConfiguration
            .refreshForServiceStart(currentMonitors: monitorConfiguration.currentMonitorsProvider())
        {
            controller.syncMonitorsToNiriEngine()
        }
        controller.hasStartedServices = true
        controller.updateWorkspaceBarNotificationBadgeSettings()
        controller.reconcileEnabledAndHotkeysState()
        controller.eventIntake.open(sink: controller.eventInterpreter)
        controller.layoutRefreshController.setup()
        controller.axManager.onAppLaunched = { [weak controller] app in
            controller?.refreshUnavailableWorkspaceBarIconOverride(
                bundleId: app.bundleIdentifier
            )
            EventIntake.post(.application(.launched(pid: app.processIdentifier)))
        }
        controller.axManager.installWorkspaceObservers()
        let runningApplications = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }
        reconcileStoppedApplicationTerminationsAndResumeTimeouts(
            liveApplicationPIDs: Set(runningApplications.lazy.map(\.processIdentifier))
        )
        controller.axEventHandler.setup()
        for app in runningApplications {
            controller.refreshUnavailableWorkspaceBarIconOverride(
                bundleId: app.bundleIdentifier
            )
        }
        connectAXFrameCallbacks(controller)
        workspaceObservation.setupWorkspaceObservation()
        controller.mouseEventHandler.setup()
        controller.syncMouseWarpPolicy()
        controller.syncWorkspaceBarRevealMonitor()
        monitorConfiguration.startObserving()
        workspaceObservation.setupAppActivationObserver()
        workspaceObservation.setupAppDeactivationObserver()
        workspaceObservation.setupAppHideObservers()
        controller.axEventHandler.reconcileHiddenApplications()
        workspaceObservation.setupSleepWakeObservation()
        controller.workspaceManager.onGapsChanged = { [weak self] in
            self?.handleGapsChanged()
        }

        controller.spaceTracker.start()
        startLockScreenObserver()
        performStartupRefresh()
        startSecureInputMonitor()
    }

    private func connectAXFrameCallbacks(_ controller: WMController) {
        controller.axManager.onTerminalFrameRefusal = { [weak controller] refusal in
            controller?.axEventHandler.handleTerminalFrameRefusal(refusal)
        }
        controller.axManager.onFrameApplyTerminated = { [weak controller] result in
            controller?.mouseEventHandler.handleNativeTitleBarDragFrameApplyTerminated(result)
        }
        controller.axManager.onFrameApplySucceeded = { [weak self] result in
            self?.handleFrameApplySucceeded(result)
        }
        controller.axManager.onStableSizeClamp = { [weak controller] result in
            controller?.adoptObservedMinimumAfterStableSizeClamp(result)
        }
        controller.axManager.onManagedWindowBindingFailed = { [weak controller] pid in
            controller?.layoutRefreshController.requestFullRescan(
                reason: .staleFullRescan,
                scope: .targeted(appPIDs: [pid], nativeSpaceIds: [])
            )
        }
    }

    private func disconnectAXCallbacks(_ controller: WMController) {
        controller.axManager.onAppLaunched = nil
        controller.axManager.onTerminalFrameRefusal = nil
        controller.axManager.onFrameApplyTerminated = nil
        controller.axManager.onFrameApplySucceeded = nil
        controller.axManager.onStableSizeClamp = nil
        controller.axManager.onManagedWindowBindingFailed = nil
    }

    func handleFrameApplySucceeded(_ result: AXFrameApplyResult) {
        guard let controller else { return }
        controller.axEventHandler.clearTerminalFrameFailure(windowId: result.windowId)
        controller.mouseEventHandler.handleNativeTitleBarDragFrameApplySucceeded(result)
        guard result.writeResult.observedFrame != nil, result.confirmedFrame != nil else { return }
        controller.relaxObservedSizeEvidence(afterVerifiedWrite: result)
        controller.surfaceReconciler.handleVerifiedFrameApplySuccess(result)
    }

    func startLockScreenObserver() {
        guard let controller else { return }
        controller.lockScreenObserver.onLockDetected = { [weak controller] in
            controller?.isLockScreenActive = true
        }
        controller.lockScreenObserver.onUnlockDetected = { [weak controller] in
            guard let controller else { return }
            controller.isLockScreenActive = false
            controller.serviceLifecycleManager.handleUnlockDetected()
        }
        controller.lockScreenObserver.start()
        let isLockScreenActive = controller.lockScreenObserver.isFrontmostAppLockScreen()
        if isLockScreenActive {
            controller.isLockScreenActive = true
            controller.layoutRefreshController.suspendForLockScreen()
            return
        }
        guard controller.isLockScreenActive != isLockScreenActive else { return }
        controller.isLockScreenActive = isLockScreenActive
        handleUnlockDetected()
    }

    func startSecureInputMonitor() {
        guard let controller else { return }
        controller.secureInputMonitor.start { [weak self] isSecure in
            self?.handleSecureInputChange(isSecure)
        }
    }

    private func handleSecureInputChange(_ isSecure: Bool) {
        guard let controller else { return }
        if isSecure {
            controller.resetWorkspaceBarReveal()
            if controller.hotkeysEnabled {
                SecureInputIndicatorController.shared.show()
            }
        } else {
            SecureInputIndicatorController.shared.hide()
        }
    }

    func reconcileStoppedApplicationTerminationsAndResumeTimeouts(liveApplicationPIDs: Set<pid_t>) {
        guard let controller else { return }
        let trackedPIDs = Set(controller.workspaceManager.allEntries().lazy.map(\.pid))
        let terminatedPIDs = trackedPIDs.subtracting(liveApplicationPIDs).sorted()
        if !terminatedPIDs.isEmpty {
            for pid in terminatedPIDs {
                _ = controller.eventIntake.enqueue(
                    .application(.terminated(pid: pid, frontmostPID: nil))
                )
            }
            controller.eventIntake.drainNow()
        }
        controller.workspaceManager.resumeNativeFullscreenTransitionTimeouts()
    }

    func handleGapsChanged() {
        controller?.layoutRefreshController.requestRelayout(reason: .gapsChanged)
    }

    func handleUnlockDetected() {
        guard let controller else { return }
        controller.axEventHandler.reconcileHiddenApplications()
        topologyInventory.schedule(reason: .unlock)
        controller.mouseEventHandler.requestMultitouchRevalidation(.unlock)
    }

    func handleSystemWake() {
        guard let controller else { return }
        _ = controller.workspaceManager.recordReconcileEvent(.systemWake(source: .service))
        controller.axEventHandler.reconcileHiddenApplications()
        controller.workspaceBarManager.cleanup()
        topologyInventory.schedule(reason: .unlock)
        controller.mouseEventHandler.requestMultitouchRevalidation(.wake)
    }

    func performStartupRefresh() {
        guard let controller else { return }
        controller.surfaceReconciler.noteWorldChanged()
        controller.layoutRefreshController.requestFullRescan(reason: .startup)
    }

    func handleActiveSpaceDidChange() {
        guard let controller else { return }
        topologyInventory.schedule(
            reason: .activeSpaceChanged,
            baseline: controller.workspaceManager.spaceTopology
        )
    }

    func stop() {
        guard !isStoppingForUser else { return }
        stopServices(retainingAXWorkers: false)
    }

    func stopServices(retainingAXWorkers: Bool) {
        guard let controller else { return }
        controller.reconcileEnabledAndHotkeysState()
        if !retainingAXWorkers, let request = controller.intentLedger.activeManagedRequest,
           case .awaitingSameAppActivation = request.phase
        {
            controller.cancelManagedFocusRequestAndRestoreSource(request)
        }
        controller.hasStartedServices = false
        controller.updateWorkspaceBarNotificationBadgeSettings()
        controller.invalidateOverviewDeferredActionsForServiceStop()
        topologyInventory.cancel()

        if !retainingAXWorkers { clearStoppedVisibility(controller) }

        controller.eventIntake.close()
        controller.factResolver.stop()
        controller.deadlineWheel.stop()
        controller.workspaceManager.cancelNativeFullscreenTransitionTimeouts()
        controller.intentLedger.reset()
        clearPendingManagedFocus(controller)
        disconnectAXCallbacks(controller)
        controller.workspaceManager.onGapsChanged = nil

        controller.mouseEventHandler.cleanup()
        controller.layoutRefreshController.resetState()
        controller.resetMouseWarpPolicy()
        controller.axEventHandler.cleanup()

        controller.tabRailManager.removeAll()
        controller.nativeFullscreenPlaceholderManager.removeAll()
        controller.surfaceReconciler.cleanup()
        controller.cleanupUIOnStop()

        if retainingAXWorkers {
            controller.axManager.prepareForStopRestoration()
        } else {
            controller.axManager.cleanup()
        }

        SkyLight.shared.stopWindowInfoQueries()

        monitorConfiguration.stopObserving()

        workspaceObservation.stop()

        controller.secureInputMonitor.stop()
        SecureInputIndicatorController.shared.hide()
        controller.lockScreenObserver.stop()
        permissionCheckerTask?.cancel()
        permissionCheckerTask = nil
        controller.reconcileEnabledAndHotkeysState()
    }
}

extension ServiceLifecycleManager {
    private func clearStoppedVisibility(_ controller: WMController) {
        let hiddenPIDs = controller.workspaceManager.hiddenAppPIDs
        let trackedPIDs = Set(controller.workspaceManager.allEntries().map(\.pid))
        for pid in trackedPIDs.subtracting(hiddenPIDs) {
            controller.workspaceManager.invalidateAppVisibility(for: pid, source: .service)
        }
        for pid in hiddenPIDs {
            let entries = controller.workspaceManager.entries(forPid: pid)
            controller.axManager.setMacOSAppHidden(
                false, pid: pid, entries: entries.map { (pid: $0.pid, windowId: $0.windowId) }
            )
        }
        controller.workspaceManager.replaceHiddenAppPIDs([], source: .service)
    }

    private func clearPendingManagedFocus(_ controller: WMController) {
        let pendingManagedFocus = controller.workspaceManager.reconcileSnapshot().focusSession.pendingManagedFocus
        guard pendingManagedFocus != .empty else { return }
        controller.workspaceManager.recordReconcileEvent(
            .managedFocusCancelled(
                token: nil,
                workspaceId: nil,
                requestId: pendingManagedFocus.requestId,
                source: .service
            )
        )
    }
}
