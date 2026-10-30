// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Observation
import OmniWMIPC

struct MonitorSetupPresentationPolicy {
    static func shouldAutomaticallyPresent(
        status: MonitorSetupStatus,
        monitors: [Monitor],
        launchOverlayFinished: Bool
    ) -> Bool {
        status == .notPresented
            && monitors.count >= 2
            && monitors.allSatisfy { $0.frame.width > 1 && $0.frame.height > 1 }
            && launchOverlayFinished
    }
}

@MainActor @Observable
public final class AppBootstrapState {
    var settings: SettingsStore?
    var controller: WMController?
    var updateCoordinator: (any AppUpdateCoordinating)?

    public init() {}

    public var isReady: Bool {
        settings != nil && controller != nil
    }

    public func registerRedirectWindow(_ window: NSWindow) {
        OwnedWindowRegistry.shared.register(window)
    }

    public func unregisterRedirectWindow(_ window: NSWindow) {
        OwnedWindowRegistry.shared.unregister(window)
    }

    public func showSettingsAndCloseRedirectWindow(_ window: NSWindow?) {
        guard let settings, let controller else { return }
        SettingsWindowController.shared.show(
            settings: settings,
            controller: controller,
            updateCoordinator: updateCoordinator
        )
        guard let window else { return }
        unregisterRedirectWindow(window)
        DispatchQueue.main.async {
            window.close()
        }
    }
}

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    public nonisolated(unsafe) weak static var sharedBootstrap: AppBootstrapState?

    override public init() {
        super.init()
    }

    var welcomeWindowController = WelcomeWindowController.shared
    private var statusBarController: StatusBarController?
    private var ipcServer: IPCServerLifecycle?
    private var cliManager: AppCLIManager?
    private var updateCoordinator: (any AppUpdateCoordinating)?
    private var runtimeStateStore: RuntimeStateStore?
    private var launchOverlayController: LaunchOverlayController?
    private var settingsConfigNoticeController: SettingsConfigNoticeController?
    private(set) var monitorSetupScreenObserver: NSObjectProtocol?
    private(set) var monitorSetupEvaluationTask: Task<Void, Never>?
    private var launchOverlayFinished = false
    private var launchPermissionsWindowController: LaunchPermissionsWindowController?
    private var didFinishBootstrap = false
    private var terminationPending = false

    public func applicationDidFinishLaunching(_: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        _ = OmniWMBuildInfo.executableSHA256
        bootstrapApplication()
    }

    public func applicationWillTerminate(_: Notification) {
        settingsConfigNoticeController = nil
        statusBarController?.cleanup()
        if let controller = AppDelegate.sharedBootstrap?.controller {
            if !terminationPending { controller.serviceLifecycleManager.stop() }
            controller.workspaceManager.flushPersistedWindowRestoreCatalogNow()
        }
        AppDelegate.sharedBootstrap?.settings?.flushNow()
        stopMonitorSetupPresentationObservation()
        stopIPCServer()
        runtimeStateStore?.flushNow()
    }

    func bootstrapApplication() {
        let checker = LaunchConflictChecker()
        LaunchConflictGate.run(
            scan: checker.scan,
            present: { reason in
                self.presentLaunchConflictAlert(reason: reason, rescan: checker.scan)
            },
            onClear: beginPermissionGate,
            onQuit: { NSApplication.shared.terminate(nil) }
        )
    }

    private func beginPermissionGate() {
        guard !didFinishBootstrap, launchPermissionsWindowController == nil else { return }

        let runtimeState = RuntimeStateStore(directory: OmniWMStoragePaths.live.stateDirectory)
        runtimeStateStore = runtimeState
        let windowController = LaunchPermissionsWindowController(runtimeState: runtimeState)
        guard windowController.needsPrompt else {
            finishBootstrap(runtimeState: runtimeState)
            return
        }

        launchPermissionsWindowController = windowController
        NSApplication.shared.setActivationPolicy(.regular)
        windowController.show(
            onStart: { [weak self] in
                self?.endPermissionGate()
                self?.finishBootstrap(runtimeState: runtimeState)
            },
            onQuit: { [weak self] in
                self?.endPermissionGate()
                NSApplication.shared.terminate(nil)
            }
        )
    }

    private func endPermissionGate() {
        launchPermissionsWindowController = nil
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    func finishBootstrap(runtimeState: RuntimeStateStore) {
        guard !didFinishBootstrap else { return }
        didFinishBootstrap = true

        let storagePaths = OmniWMStoragePaths.live

        let settings = SettingsStore(
            persistence: SettingsFilePersistence(directory: storagePaths.configDirectory),
            runtimeState: runtimeState
        )
        let menuBarHold = MenuBarAutohideHold(runtimeState: runtimeState)
        let hiddenBarController = HiddenBarController.live(
            settings: settings,
            menuBarHold: menuBarHold,
            stateDirectory: storagePaths.stateDirectory
        )
        let controller = WMController(
            settings: settings,
            hiddenBarController: hiddenBarController,
            clipboardHistoryDirectory: storagePaths.stateDirectory
        )
        controller.workspaceBarManager.menuBarHold = menuBarHold
        controller.applyPersistedSettings(settings)
        startSystemPreferenceObservation(controller)
        let cliManager = AppCLIManager()
        let updateCoordinator = UpdateCoordinator(settings: settings, runtimeState: runtimeState)
        self.cliManager = cliManager
        self.updateCoordinator = updateCoordinator

        AppDelegate.sharedBootstrap?.settings = settings
        AppDelegate.sharedBootstrap?.controller = controller
        AppDelegate.sharedBootstrap?.updateCoordinator = updateCoordinator

        FatalCapture.install(controllerProvider: { AppDelegate.sharedBootstrap?.controller })
        controller.pendingCrashReport = FatalCapture.consumePending()

        statusBarController = StatusBarController(
            settings: settings,
            controller: controller,
            hiddenBarController: hiddenBarController,
            cliManager: cliManager,
            updateCoordinator: updateCoordinator,
            openWelcome: { [weak self] in self?.presentWelcome(settings: $0, controller: $1, reason: .reopened) }
        )
        controller.statusBarController = statusBarController
        settingsConfigNoticeController = SettingsConfigNoticeController(
            settings: settings,
            ownedWindowRegistry: controller.ownedWindowRegistry
        )
        observeSettings(settings, controller: controller)
        statusBarController?.setup()
        startIPC(settings: settings, controller: controller)
        updateCoordinator.startAutomaticChecks()

        beginLaunchPresentation(runtimeState: runtimeState, controller: controller)
    }

    private func startIPC(settings: SettingsStore, controller: WMController) {
        do {
            try setIPCEnabled(settings.ipcEnabled, controller: controller)
        } catch {
            presentInfoAlert(
                title: String(localized: "IPC Failed to Start"),
                message: error.localizedDescription
            )
            settings.ipcEnabled = false
        }
    }

    private func observeSettings(_ settings: SettingsStore, controller: WMController) {
        settings.onIPCEnabledChanged = { [weak self, weak controller] isEnabled in
            guard let self, let controller else { return }
            do {
                try self.setIPCEnabled(isEnabled, controller: controller)
            } catch {
                self.presentInfoAlert(
                    title: String(localized: "IPC Failed to Start"),
                    message: error.localizedDescription
                )
                if isEnabled {
                    settings.ipcEnabled = false
                }
            }
        }
        settings.onExternalSettingsReloaded = { [weak controller] in
            guard let controller else { return }
            controller.applyPersistedSettings(settings)
        }
        settings.onConfigNoticeChanged = { [weak self, weak controller] in
            controller?.refreshDiagnosticsIssues()
            guard let self, launchOverlayFinished else { return }
            settingsConfigNoticeController?.refresh()
        }
    }

    func startIPCServer(controller: WMController) throws {
        if ipcServer != nil {
            stopIPCServer()
        }
        let server = IPCServer(controller: controller)
        try server.start()
        ipcServer = server
    }

    func setIPCEnabled(_ enabled: Bool, controller: WMController) throws {
        if enabled {
            try startIPCServer(controller: controller)
        } else {
            stopIPCServer()
        }
    }

    private func stopIPCServer() {
        ipcServer?.stop()
        ipcServer = nil
    }

    func startMonitorSetupPresentationObservation() {
        guard monitorSetupScreenObserver == nil else { return }
        monitorSetupScreenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleMonitorSetupEvaluation()
            }
        }
    }

    func scheduleMonitorSetupEvaluation() {
        guard launchOverlayFinished, monitorSetupScreenObserver != nil,
              !welcomeWindowController.isVisible else { return }
        monitorSetupEvaluationTask?.cancel()
        monitorSetupEvaluationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.evaluateMonitorSetupPresentation()
        }
    }

    func evaluateMonitorSetupPresentation(monitors: [Monitor] = Monitor.current()) {
        guard let bootstrap = AppDelegate.sharedBootstrap,
              let settings = bootstrap.settings,
              let controller = bootstrap.controller
        else { return }
        let shouldPresent = MonitorSetupPresentationPolicy.shouldAutomaticallyPresent(
            status: settings.monitorSetupStatus,
            monitors: monitors,
            launchOverlayFinished: launchOverlayFinished
        )
        guard shouldPresent, !welcomeWindowController.isVisible else {
            if settings.monitorSetupStatus != .notPresented {
                stopMonitorSetupPresentationObservation()
            }
            return
        }

        settings.monitorSetupStatus = .dismissed
        stopMonitorSetupPresentationObservation()
        SettingsWindowController.shared.show(
            settings: settings,
            controller: controller,
            updateCoordinator: bootstrap.updateCoordinator,
            presentMonitorSetup: true
        )
    }

    func stopMonitorSetupPresentationObservation() {
        monitorSetupEvaluationTask?.cancel()
        monitorSetupEvaluationTask = nil
        if let monitorSetupScreenObserver {
            NotificationCenter.default.removeObserver(monitorSetupScreenObserver)
            self.monitorSetupScreenObserver = nil
        }
    }

    private func presentLaunchConflictAlert(
        reason: LaunchConflictBlockReason,
        rescan: @escaping @MainActor () -> LaunchConflictCheckResult
    ) -> LaunchConflictGateAction {
        let previousApplication = NSWorkspace.shared.frontmostApplication.flatMap { application in
            application.processIdentifier == getpid() ? nil : application
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        switch reason {
        case let .conflicts(conflicts):
            alert.messageText = String(localized: "Conflicting Window Managers Detected")
            let conflictList = conflicts.map { "• \($0.displayName)" }.joined(separator: "\n")
            alert.informativeText = String(localized:
                "OmniWM has not started. Quit these window managers or stop their background services. OmniWM continues automatically once they are gone, or click Check Again:\n\n\(conflictList)"
            )
        case let .unidentifiedProcess(pid):
            alert.messageText = String(localized: "Couldn’t Identify a Running Process")
            alert.informativeText = String(localized:
                "OmniWM has not started because it could not identify process \(pid) (see `ps -p \(pid)`). It retries every second; click Check Again to retry now, or quit OmniWM."
            )
        case .scanUnavailable:
            alert.messageText = String(localized: "Couldn’t Check Running Processes")
            alert.informativeText = String(localized:
                "OmniWM has not started because it could not safely inspect every running process. It retries every second; click Check Again to retry now, or quit OmniWM."
            )
        }
        alert.addButton(withTitle: String(localized: "Check Again"))
        alert.addButton(withTitle: String(localized: "Quit OmniWM"))
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        NSApplication.shared.activate(ignoringOtherApps: true)
        let autoRecheck = LaunchConflictAutoRecheck(scan: rescan) {
            NSApplication.shared.abortModal()
        }
        autoRecheck.start()
        let response = alert.runModal()
        autoRecheck.stop()
        let action: LaunchConflictGateAction = response == .alertSecondButtonReturn ? .quit : .checkAgain
        if action == .checkAgain {
            NSApplication.shared.deactivate()
            if let previousApplication, !previousApplication.isTerminated {
                previousApplication.activate(options: [])
            }
        }
        return action
    }

    private func presentInfoAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "OK"))
        NSApplication.shared.activate(ignoringOtherApps: true)
        _ = alert.runModal()
    }

    private func confirmQuitWithoutSavingClipboardHistory(_ error: Error) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Clipboard History Could Not Be Saved")
        alert.informativeText = String(localized:
            "\(error.localizedDescription)\n\nQuit anyway? Unsaved clipboard history will be lost."
        )
        alert.addButton(withTitle: String(localized: "Keep OmniWM Open"))
        alert.addButton(withTitle: String(localized: "Quit Without Saving"))
        NSApplication.shared.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn
    }
}

extension AppDelegate {
    private func beginLaunchPresentation(runtimeState: RuntimeStateStore, controller: WMController) {
        startMonitorSetupPresentationObservation()
        let overlay = LaunchOverlayController()
        launchOverlayController = overlay
        overlay.play(
            runtimeState: runtimeState,
            animationsEnabled: controller.motionPolicy.animationsEnabled
        ) { [weak self] in
            guard let self else { return }
            launchOverlayController = nil
            launchOverlayDidFinish(runtimeState: runtimeState, controller: controller)
        }
    }

    func launchOverlayDidFinish(runtimeState: RuntimeStateStore, controller: WMController) {
        launchOverlayFinished = true
        settingsConfigNoticeController?.refresh()
        presentWelcomeIfNeeded(runtimeState: runtimeState, controller: controller)
    }

    private func presentWelcomeIfNeeded(runtimeState: RuntimeStateStore, controller: WMController) {
        guard !runtimeState.welcomePresented else {
            scheduleMonitorSetupEvaluation()
            return
        }
        presentWelcome(settings: controller.settings, controller: controller, reason: .firstRun)
        runtimeState.welcomePresented = true
    }

    func presentWelcome(settings: SettingsStore, controller: WMController, reason: WelcomeReason) {
        monitorSetupEvaluationTask?.cancel()
        monitorSetupEvaluationTask = nil
        welcomeWindowController.show(settings: settings, controller: controller, reason: reason) { [weak self] in
            if reason == .firstRun {
                self?.scheduleMonitorSetupEvaluation()
            }
        }
    }

    private func startSystemPreferenceObservation(_ controller: WMController) {
        controller.motionPolicy.systemReducesMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        _ = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak controller] _ in
            Task { @MainActor [weak controller] in
                controller?.motionPolicy.systemReducesMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            }
        }
        for name in [
            Notification.Name("NSWorkspaceIconAppearanceConfigurationDidChangeNotification"),
            Notification.Name("NSWorkspaceMenuBarAppearanceDidChangeNotification")
        ] {
            _ = NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak controller] _ in
                Task { @MainActor [weak controller] in
                    guard let controller else { return }
                    LauncherIconStore.shared.clear()
                    controller.workspaceBarManager.refreshShellIcons()
                }
            }
        }
    }

    public func applicationShouldTerminate(_ application: NSApplication) -> NSApplication.TerminateReply {
        guard let controller = AppDelegate.sharedBootstrap?.controller else { return .terminateNow }
        return deferTermination(
            stop: { completion in
                Task { @MainActor in
                    do {
                        try await controller.clipboardHistoryService.flushForQuit()
                    } catch {
                        if !self.confirmQuitWithoutSavingClipboardHistory(error) {
                            controller.clipboardHistoryService.resumeAfterCanceledQuit()
                            self.terminationPending = false
                            application.reply(toApplicationShouldTerminate: false)
                            return
                        }
                    }
                    await controller.workspaceBarManager.flushShellForQuit()
                    controller.serviceLifecycleManager.stopRestoringWindows(forQuit: true, completion: completion)
                }
            },
            reply: {
                controller.workspaceManager.flushPersistedWindowRestoreCatalogNow()
                application.reply(toApplicationShouldTerminate: true)
            }
        )
    }

    func deferTermination(
        stop: @escaping (@escaping @MainActor @Sendable () -> Void) -> Void,
        reply: @escaping @MainActor @Sendable () -> Void
    ) -> NSApplication.TerminateReply {
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        Task { @MainActor in stop(reply) }
        return .terminateLater
    }
}
