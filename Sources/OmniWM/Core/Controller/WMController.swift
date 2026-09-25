// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import OmniWMIPC

@MainActor @Observable
final class WMController {
    private struct BorderLayoutConfig: Equatable {
        let enabled: Bool
        let width: CGFloat

        func clearance(scale: CGFloat) -> CGFloat {
            BorderConfig.layoutClearance(enabled: enabled, width: width, scale: scale)
        }
    }

    var isEnabled: Bool = true
    var hotkeysEnabled: Bool = true
    private(set) var desiredEnabled: Bool = true
    private(set) var desiredHotkeysEnabled: Bool = true
    private(set) var accessibilityPermissionGranted = AccessibilityPermissionMonitor.shared.isGranted
    private(set) var focusFollowsMouseEnabled: Bool = false
    private(set) var moveMouseToFocusedWindowEnabled: Bool = false
    private(set) var displaySpacesMode: DisplaySpacesMode = .enabled
    private var displaySpacesAlertShown = false
    var pendingCrashReport: FatalCapture.PendingCrashReport?
    var diagnosticsIssues: [DiagnosticsIssue] = []

    let settings: SettingsStore
    @ObservationIgnored
    private var appliedBorderLayoutConfig: BorderLayoutConfig
    let workspaceManager: WorkspaceManager
    @ObservationIgnored
    let windowMarkRegistry = WindowMarkRegistry()
    let hotkeys = HotkeyCenter()
    private(set) var hotkeyRegistrationFailures: [HotkeyCommand: HotkeyRegistrationFailureReason] = [:]
    private(set) var systemHyperTriggerFailure: SystemHyperTriggerFailure?
    var isHyperTriggerActive: Bool {
        hotkeys.isHyperTriggerActive
    }

    let secureInputMonitor = SecureInputMonitor()
    let lockScreenObserver = LockScreenObserver()
    var isLockScreenActive: Bool = false {
        didSet {
            guard oldValue != isLockScreenActive else { return }
            if isLockScreenActive {
                layoutRefreshController.suspendForLockScreen()
                resetWorkspaceBarReveal()
                mouseEventHandler.handleInputSuppressionBegan()
            } else {
                layoutRefreshController.awaitPostUnlockTopologySample()
            }
        }
    }

    let axManager = AXManager()
    let traceCaptureCoordinator: RuntimeTraceCaptureCoordinator
    let appInfoCache = AppInfoCache()
    @ObservationIgnored
    let workspaceBarIconResolver: WorkspaceBarIconResolver
    private(set) var workspaceBarIconResolutionRevision: UInt64 = 0
    let eventIntake = EventIntake()
    let factResolver = FactResolver()
    let intentLedger = IntentLedger()
    let deadlineWheel = DeadlineWheel()
    @ObservationIgnored
    private(set) lazy var scratchpadStacking = ScratchpadStackingController(controller: self)
    @ObservationIgnored
    var scheduleScratchpadStackingContinuation: (@escaping @MainActor () -> Void) -> Void = { continuation in
        Task { @MainActor in
            await Task.yield()
            continuation()
        }
    }

    @ObservationIgnored
    private(set) lazy var eventInterpreter = EventInterpreter(controller: self)
    let focusPolicyEngine: FocusPolicyEngine
    let windowRuleEngine = WindowRuleEngine()

    @ObservationIgnored
    private(set) lazy var tabRailManager = TabRailManager(motionPolicy: motionPolicy, appInfoCache: appInfoCache)
    @ObservationIgnored
    lazy var nativeFullscreenPlaceholderManager: NativeFullscreenPlaceholderManager = {
        let manager = NativeFullscreenPlaceholderManager()
        manager.appInfoCache = appInfoCache
        manager.onActivate = { [weak self] originalToken in
            self?.activateNativeFullscreenPlaceholder(originalToken)
        }
        return manager
    }()

    @ObservationIgnored
    private(set) lazy var surfaceReconciler = SurfaceReconciler(controller: self)
    @ObservationIgnored
    private(set) lazy var workspaceBarManager: WorkspaceBarManager = .init(motionPolicy: motionPolicy)
    @ObservationIgnored
    private var runtimeFrameJobCancellationSuppressionDepth: Int = 0
    @ObservationIgnored
    let floatDemotionTracker = FloatDemotionTracker()
    @ObservationIgnored
    private var hiddenWorkspaceBarMonitorIds: Set<Monitor.ID> = []
    @ObservationIgnored
    private var isWorkspaceBarRevealHeld = false
    @ObservationIgnored
    private lazy var workspaceBarRevealMonitor: WorkspaceBarRevealMonitor = {
        let monitor = WorkspaceBarRevealMonitor()
        monitor.onRevealChanged = { [weak self] revealed in
            self?.setWorkspaceBarRevealHeld(revealed)
        }
        return monitor
    }()

    @ObservationIgnored
    let hiddenBarController: HiddenBarController
    @ObservationIgnored
    private(set) lazy var quakeTerminalController: QuakeTerminalController = .init(
        settings: settings,
        motionPolicy: motionPolicy,
        captureRestoreTarget: { [weak self] in
            guard let self else { return nil }
            return self.captureQuakeTerminalRestoreTarget()
        },
        restoreFocusTarget: { [weak self] target in
            self?.restoreQuakeTerminalFocus(to: target)
        },
        focusedWindowScreenProvider: { [weak self] in
            self?.focusedManagedWindowScreenForQuakeTerminal()
        }
    )
    @ObservationIgnored
    private(set) lazy var commandPaletteController: CommandPaletteController = .init(motionPolicy: motionPolicy)

    @ObservationIgnored
    private(set) lazy var systemStatsPopupController: SystemStatsPopupController = {
        let controller = SystemStatsPopupController()
        controller.isToggleSourceWindow = { [weak self] window in
            self?.workspaceBarManager.isWorkspaceBarWindow(window) ?? false
        }
        return controller
    }()

    @ObservationIgnored
    private(set) lazy var sponsorsWindowController: SponsorsWindowController = .init(
        motionPolicy: motionPolicy,
        ownedWindowRegistry: ownedWindowRegistry
    )

    var isTransferringWindow: Bool = false

    @ObservationIgnored
    private(set) lazy var mouseEventHandler = MouseEventHandler(controller: self)
    @ObservationIgnored
    private(set) lazy var mouseWarpHandler = MouseWarpHandler(controller: self)
    @ObservationIgnored
    private(set) lazy var axEventHandler = AXEventHandler(controller: self)
    @ObservationIgnored
    private(set) lazy var placementResolver = PlacementResolver(workspaceManager: workspaceManager)
    @ObservationIgnored
    private(set) lazy var spaceTracker = SpaceTracker(controller: self)
    @ObservationIgnored
    private(set) lazy var commandHandler = CommandHandler(controller: self)
    @ObservationIgnored
    private(set) lazy var workspaceNavigationHandler = WorkspaceNavigationHandler(controller: self)
    @ObservationIgnored
    private(set) lazy var layoutRefreshController = LayoutRefreshController(controller: self)
    var niriLayoutHandler: NiriLayoutHandler {
        layoutRefreshController.niriHandler
    }

    var dwindleLayoutHandler: DwindleLayoutHandler {
        layoutRefreshController.dwindleHandler
    }

    @ObservationIgnored
    private(set) lazy var serviceLifecycleManager = ServiceLifecycleManager(controller: self)
    @ObservationIgnored
    private(set) var windowActionHandlerStorage: WindowActionHandler?
    var windowActionHandler: WindowActionHandler {
        if let windowActionHandlerStorage {
            return windowActionHandlerStorage
        }
        let handler = WindowActionHandler(controller: self)
        windowActionHandlerStorage = handler
        return handler
    }

    @ObservationIgnored
    lazy var clipboardHistoryService = ClipboardHistoryService(configuration: clipboardHistoryConfiguration())
    @ObservationIgnored
    private(set) lazy var focusNotificationDispatcher = FocusNotificationDispatcher(controller: self)
    @ObservationIgnored
    var hasStartedServices = false
    @ObservationIgnored
    private(set) var isMouseWarpPolicyEnabled = false
    @ObservationIgnored
    let ownedWindowRegistry: OwnedWindowRegistry
    @ObservationIgnored
    var warpMouseCursorPosition: (CGPoint) -> Void = { CGWarpMouseCursorPosition($0) }
    @ObservationIgnored
    var currentMouseLocation: () -> CGPoint = { NSEvent.mouseLocation }
    @ObservationIgnored
    weak var ipcApplicationBridge: IPCApplicationBridge?

    let animationClock = AnimationClock()
    let motionPolicy: MotionPolicy
    let diagnosticsDirectory: URL
    private let clipboardHistoryDirectory: URL
    let windowFocusOperations: WindowFocusOperations
    weak var statusBarController: StatusBarController?
    @ObservationIgnored
    var effectiveAppearanceObserver: NSKeyValueObservation?
    @ObservationIgnored
    var borderUsesDarkAppearance = false

    init(
        settings: SettingsStore,
        hiddenBarController: HiddenBarController? = nil,
        clipboardHistoryDirectory: URL = OmniWMStoragePaths.live.stateDirectory,
        diagnosticsDirectory: URL = OmniWMStoragePaths.live.diagnosticsDirectory,
        windowFocusOperations: WindowFocusOperations = .live,
        ownedWindowRegistry: OwnedWindowRegistry = .shared,
        workspaceBarIconResolver: WorkspaceBarIconResolver? = nil
    ) {
        self.settings = settings
        appliedBorderLayoutConfig = BorderLayoutConfig(
            enabled: settings.borders.enabled,
            width: CGFloat(settings.borders.width)
        )
        self.workspaceBarIconResolver = workspaceBarIconResolver
            ?? WorkspaceBarIconResolver(settingsFileURL: settings.settingsFileURL)
        motionPolicy = MotionPolicy(animationsEnabled: settings.animationsEnabled)
        self.hiddenBarController = hiddenBarController ?? HiddenBarController(settings: settings)
        self.clipboardHistoryDirectory = clipboardHistoryDirectory
        self.diagnosticsDirectory = diagnosticsDirectory
        traceCaptureCoordinator = RuntimeTraceCaptureCoordinator(diagnosticsDirectory: diagnosticsDirectory)
        self.windowFocusOperations = windowFocusOperations
        self.ownedWindowRegistry = ownedWindowRegistry
        workspaceManager = WorkspaceManager(settings: settings)
        focusPolicyEngine = FocusPolicyEngine()
        if self.workspaceBarIconResolver.synchronize(
            overrides: settings.workspaceBar.iconOverrides
        ) {
            workspaceBarIconResolutionRevision = 1
        }
        configureInputRouting()
        configureSurfaceCallbacks()
        configureWorldCallbacks()
        configureFocusAndMenuCallbacks()
        installEffectiveAppearanceObserver()
    }
}

extension WMController {
    func setEnabled(_ enabled: Bool) {
        desiredEnabled = enabled
        if enabled {
            serviceLifecycleManager.start()
        } else {
            serviceLifecycleManager.stopRestoringWindows()
        }
        reconcileEnabledAndHotkeysState()
    }

    func setHotkeysEnabled(_ enabled: Bool) {
        desiredHotkeysEnabled = enabled
        reconcileEnabledAndHotkeysState()
    }

    func updateAccessibilityPermissionGranted(_ granted: Bool) {
        accessibilityPermissionGranted = granted
        reconcileEnabledAndHotkeysState()
    }

    func updateDisplaySpacesMode(_ mode: DisplaySpacesMode) {
        guard displaySpacesMode != mode else { return }
        displaySpacesMode = mode
        if mode == .disabled, !displaySpacesAlertShown {
            displaySpacesAlertShown = true
            presentSeparateSpacesAlert()
        }
    }

    func reconcileEnabledAndHotkeysState() {
        isEnabled = desiredEnabled && accessibilityPermissionGranted
            && !serviceLifecycleManager.isStoppingForUser && !serviceLifecycleManager.quitRequested

        let shouldEnableHotkeys = desiredHotkeysEnabled
            && isEnabled
            && hasStartedServices
            && !serviceLifecycleManager.isSecureInputActive
        hotkeysEnabled = shouldEnableHotkeys
        if shouldEnableHotkeys {
            hotkeys.start()
        } else {
            hotkeys.stop()
        }
        refreshHotkeyFailureSnapshots()
    }

    func borderSettingsChanged() {
        let current = BorderLayoutConfig(
            enabled: settings.borders.enabled,
            width: CGFloat(settings.borders.width)
        )
        let previous = appliedBorderLayoutConfig
        appliedBorderLayoutConfig = current
        let clearanceChanged = workspaceManager.monitors.contains { monitor in
            let scale = backingScaleFactor(for: monitor)
            return previous.clearance(scale: scale) != current.clearance(scale: scale)
        }
        if clearanceChanged {
            workspaceManager.invalidateAllLayouts()
            layoutRefreshController.requestRelayout(reason: .layoutConfigChanged)
            surfaceReconciler.noteWorldChanged()
        } else {
            surfaceReconciler.noteBorderChanged()
        }
    }

    @discardableResult
    func toggleWorkspaceBarVisibility() -> Bool {
        pruneHiddenWorkspaceBarMonitorIds()

        guard let monitor = monitorForInteraction() else { return false }
        let resolved = settings.workspaceBar.resolved(for: monitor)
        guard resolved.enabled else { return false }

        if hiddenWorkspaceBarMonitorIds.contains(monitor.id) {
            hiddenWorkspaceBarMonitorIds.remove(monitor.id)
        } else {
            hiddenWorkspaceBarMonitorIds.insert(monitor.id)
        }

        workspaceManager.invalidateAllLayouts()
        layoutRefreshController.requestRelayout(reason: .monitorSettingsChanged)
        surfaceReconciler.noteWorldChanged()
        hiddenBarController.dismissPanel()
        return true
    }

    @discardableResult
    func synchronizeWorkspaceBarIconOverrides(
        forceReload: Bool = false,
        forceReloadBundleId: String? = nil
    ) -> Bool {
        guard workspaceBarIconResolver.synchronize(
            overrides: settings.workspaceBar.iconOverrides,
            forceReload: forceReload,
            forceReloadBundleId: forceReloadBundleId
        ) else {
            return false
        }
        workspaceBarIconResolutionRevision += 1
        return true
    }

    func setFocusFollowsMouse(_ enabled: Bool) {
        focusFollowsMouseEnabled = enabled
        guard !enabled,
              let request = intentLedger.activeManagedRequest,
              request.origin == .focusFollowsMouse
        else {
            return
        }
        cancelManagedFocusRequestAndRestoreSource(request)
    }

    func setMoveMouseToFocusedWindow(_ enabled: Bool) {
        moveMouseToFocusedWindowEnabled = enabled
    }

    func syncWorkspaceBarRevealMonitor() {
        guard hasStartedServices,
              settings.workspaceBar.revealModifier != .off,
              workspaceBarRefreshIsEnabled
        else {
            workspaceBarRevealMonitor.stop()
            return
        }

        workspaceBarRevealMonitor.start(
            modifier: settings.workspaceBar.revealModifier,
            holdMilliseconds: settings.workspaceBar.revealHoldMilliseconds
        )
    }

    func setWorkspaceBarRevealHeld(_ revealed: Bool) {
        guard isWorkspaceBarRevealHeld != revealed else { return }
        isWorkspaceBarRevealHeld = revealed
        surfaceReconciler.noteWorldChanged()
    }

    func resetWorkspaceBarReveal() {
        workspaceBarRevealMonitor.resetReveal()
    }

    func refreshHotkeyFailureSnapshots() {
        hotkeyRegistrationFailures = hotkeys.registrationFailures
        systemHyperTriggerFailure = hotkeys.systemHyperTriggerFailure
    }

    var workspaceBarRefreshIsEnabled: Bool {
        settings.workspaceBar.enabled || settings.workspaceBar.monitorOverrides.contains(where: { $0.enabled == true })
    }

    var statusBarRefreshIsEnabled: Bool {
        statusBarController != nil && settings.statusBar.showWorkspaceName
    }

    var hasWorkspaceBarDataConsumers: Bool {
        workspaceBarRefreshIsEnabled
            || statusBarRefreshIsEnabled
            || ipcApplicationBridge?.hasSubscribers(for: .workspaceBar) == true
            || ipcApplicationBridge?.hasSubscribers(for: .windowsChanged) == true
            || ipcApplicationBridge?.hasSubscribers(for: .layoutChanged) == true
    }

    func isWorkspaceBarConfiguredVisible(on monitor: Monitor, resolved: ResolvedBarSettings) -> Bool {
        guard resolved.enabled, !hiddenWorkspaceBarMonitorIds.contains(monitor.id) else { return false }
        return settings.workspaceBar.revealModifier == .off || isWorkspaceBarRevealHeld
    }

    func pruneHiddenWorkspaceBarMonitorIds() {
        hiddenWorkspaceBarMonitorIds = hiddenWorkspaceBarMonitorIds.filter { monitorId in
            guard let monitor = workspaceManager.monitor(byId: monitorId) else { return false }
            return settings.workspaceBar.resolved(for: monitor).enabled
        }
    }

    func handleRuntimeInvalidation(
        workspaceId: WorkspaceDescriptor.ID?,
        domains: InvalidationDomain,
        surfaceScope: SessionSurfaceInvalidationScope
    ) {
        layoutRefreshController.workspaceSwipe.handleInvalidation(workspaceId: workspaceId, domains: domains)
        switch surfaceScope {
        case .full:
            surfaceReconciler.noteWorldChanged()
        case .border:
            surfaceReconciler.noteBorderChanged()
        }
        guard domains.contains(.workspace) || domains.contains(.fullscreen) else { return }
        guard runtimeFrameJobCancellationSuppressionDepth == 0 else { return }
        cancelPendingFrameJobsForInvalidation(workspaceId: workspaceId)
    }

    func withRuntimeFrameJobCancellationSuppressed<T>(_ body: () throws -> T) rethrows -> T {
        runtimeFrameJobCancellationSuppressionDepth += 1
        defer { runtimeFrameJobCancellationSuppressionDepth -= 1 }
        return try body()
    }

    #if DEBUG
        func testFloatingSpawnMonitorId(pid: pid_t) -> Monitor.ID? {
            placementResolver.floatingSpawnMonitorId(pid: pid)
        }
    #endif

    func clipboardHistoryConfiguration() -> ClipboardHistoryConfiguration {
        ClipboardHistoryConfiguration(
            isEnabled: settings.clipboard.historyEnabled,
            maxItems: settings.clipboard.maxItems,
            maxItemBytes: settings.clipboard.maxItemBytes,
            maxTotalBytes: settings.clipboard.maxTotalBytes,
            storageDirectory: clipboardHistoryDirectory,
            ignoredTypes: settings.clipboard.ignoredTypes
        )
    }

    @discardableResult
    func syncMouseWarpPolicy(for monitors: [Monitor]? = nil) -> Bool {
        let effectiveMonitors = monitors ?? workspaceManager.monitors
        let shouldEnable = shouldUseMouseWarp(for: effectiveMonitors)

        guard shouldEnable != isMouseWarpPolicyEnabled else {
            return shouldEnable
        }

        if shouldEnable {
            mouseWarpHandler.setup()
        } else {
            mouseWarpHandler.cleanup()
        }

        isMouseWarpPolicyEnabled = shouldEnable
        return shouldEnable
    }

    func resetMouseWarpPolicy() {
        mouseWarpHandler.cleanup()
        isMouseWarpPolicyEnabled = false
    }

    func cleanupUIOnStop() {
        workspaceBarRevealMonitor.stop()
        workspaceBarManager.cleanup()
    }
}
