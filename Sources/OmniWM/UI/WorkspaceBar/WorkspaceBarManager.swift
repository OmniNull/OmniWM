// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import OmniWMIPC
import SwiftUI

@MainActor
final class WorkspaceBarManager {
    var screenProvider: @MainActor (CGDirectDisplayID) -> NSScreen? = { displayId in
        NSScreen.screens.first(where: { $0.displayId == displayId })
    }

    var panelFactory: @MainActor @Sendable () -> WorkspaceBarPanel = {
        WorkspaceBarPanel.defaultPanel()
    }

    var frameApplier: @MainActor @Sendable (WorkspaceBarPanel, NSRect) -> Void = { panel, frame in
        panel.setFrame(frame, display: true)
    }

    private(set) var barsByMonitor: [Monitor.ID: WorkspaceBarInstance] = [:]
    weak var controller: WMController?
    private weak var settings: SettingsStore?
    let menuPresenter = WorkspaceBarMenuPresenter()
    var renamePanel: WorkspaceBarRenamePanel?
    var menuMonitorId: Monitor.ID?
    var renameMonitorId: Monitor.ID?
    let dragController = WorkspaceBarDragController()
    var autoHideTargets: [WorkspaceBarAutoHideTarget] = []
    var autoHideState = WorkspaceBarAutoHideState()
    let autoHideDelays = WorkspaceBarAutoHideDelays()
    var hoverPreview: WorkspaceBarHoverPreviewController?
    let notificationBadges: WorkspaceBarBadgeService
    var notificationBadgeTargetsByMonitor: [Monitor.ID: Set<String>] = [:]
    var shellBadgeDemand = false
    var shellBadgeTargets: Set<String> = []
    let motionPolicy: MotionPolicy
    private let surfaceCoordinator = SurfaceCoordinator.shared
    private var hiddenBarJoin: HiddenBarPanelPlacement.Join?
    var shellHost: ShellWidgetHost?
    private let configDirectory: URL
    lazy var shellConfiguration = ShellConfigurationCoordinator(
        shellDirectory: ShellWidgetHost.shellDirectory(in: configDirectory),
        onDefaultsUpdated: Self.presentReplacedShellDefaults
    ) { [weak self] config in
        self?.shellConfigurationSaved(config)
    }

    var shellEdgeHover = ShellEdgeHover()
    var shellVars: [String: String] = [:]
    var shellItemIcons: [String: NSImage] = [:]
    var shellCompactedScratchpads: [Monitor.ID: Set<Int>] = [:]
    var lastBars: [DesiredBarSurface] = []
    var lastIslands: [DesiredIslandSurface] = []
    let shellSessionToken = UUID().uuidString
    var shellPreview: ShellPreview?
    var shellDrag = ShellDragState()
    var shellHiddenBarBitmaps: Set<String> = []
    var retiredShellHiddenBarBitmaps: Set<String> = []
    var menuBarHold: MenuBarAutohideHold?

    init(
        configDirectory: URL,
        motionPolicy: MotionPolicy,
        notificationBadges: WorkspaceBarBadgeService = WorkspaceBarBadgeService()
    ) {
        self.configDirectory = configDirectory
        self.motionPolicy = motionPolicy
        self.notificationBadges = notificationBadges
    }

    func setup(controller: WMController, settings: SettingsStore) {
        self.controller = controller
        self.settings = settings
        controller.hiddenBarController.shellDrawer = makeShellHiddenBarDrawer()
        settings.liveShellNamesForHotkeys = { [weak self] in
            self?.shellHost?.toggleNames ?? []
        }
        configureDragController(controller: controller)
        syncHoverPreview(controller: controller, settings: settings)
    }

    func apply(_ bars: [DesiredBarSurface]) {
        guard controller != nil, let settings else { return }

        prepareShell(for: bars, settings: settings)
        var staleMonitorIds = Set(barsByMonitor.keys)
        for bar in bars where bar.isRetained {
            staleMonitorIds.remove(bar.monitor.id)
            let snapshot = shellSnapshot(for: bar)
            if let existing = barsByMonitor[bar.monitor.id] {
                if !updateBarForMonitor(bar.monitor, snapshot: snapshot, instance: existing) {
                    removeBarForMonitor(bar.monitor.id)
                    createBarForMonitor(bar.monitor, snapshot: snapshot)
                }
            } else {
                createBarForMonitor(bar.monitor, snapshot: snapshot)
            }
            applyVisibility(bar.visible, on: bar.monitor.id)
        }

        for monitorId in staleMonitorIds {
            removeBarForMonitor(monitorId)
        }
        updateNotificationBadgeTargets(bars)
        dragController.barsDidUpdate()
        refreshShellDrag()
        hoverPreview?.targetsDidChange { [weak self] key in
            self?.shellHoverTarget(for: key)
        }
        updateShellHiddenBarPlacement()
        rebuildAutoHideTargets()
        if let menuBarHold, let controller {
            menuBarHold.update(hiding: bars.contains { bar in
                let resolved = settings.workspaceBar.resolved(for: bar.monitor)
                return controller.isWorkspaceBarEnabled(on: bar.monitor, resolved: resolved)
                    && Self.hidesMenuBar(resolved)
            })
        }
    }

    func updateAppearance() {
        guard let settings else { return }
        refreshShellBarColors(settings)
    }

    private func createBarForMonitor(_ monitor: Monitor, snapshot: WorkspaceBarSnapshot) {
        guard controller != nil, let settings else { return }

        let resolved = settings.workspaceBar.resolved(for: monitor)
        let model = WorkspaceBarModel(snapshot: snapshot)
        model.hiddenBarJoinEdge = hiddenBarJoinEdge(on: monitor.id)
        let measurementView = NSHostingView(rootView: WorkspaceBarMeasurementView(snapshot: snapshot))
        let screen = screenProvider(monitor.displayId)
        let panel = makePanel(screen: screen)
        let primary = WorkspaceBarIslandPanel(
            panel: panel,
            rootView: makeBarView(model: model, slice: .all, monitorId: monitor.id),
            resolved: resolved,
            monitor: monitor
        )

        let instance = WorkspaceBarInstance(
            monitor: monitor,
            primary: primary,
            measurementView: measurementView,
            model: model,
            screenDisplayId: screen?.displayId
        )
        barsByMonitor[monitor.id] = instance

        instance.applyCurrentAppearance()
        updateBarFrameAndPosition(for: monitor, resolved: resolved, snapshot: snapshot, instance: instance)
        surfaceCoordinator.register(
            window: primary.panel,
            id: instance.surfaceId(),
            policy: WorkspaceBarInstance.surfacePolicy
        )
    }

    private func updateBarForMonitor(
        _ monitor: Monitor,
        snapshot: WorkspaceBarSnapshot,
        instance: WorkspaceBarInstance
    ) -> Bool {
        guard let settings else { return false }

        let screen = screenProvider(monitor.displayId)
        guard instance.updateMonitor(monitor, screen: screen) else { return false }

        let resolved = settings.workspaceBar.resolved(for: monitor)
        instance.updateSnapshot(snapshot)
        instance.applyCurrentAppearance()
        instance.applyPanelSettings(resolved: resolved)
        updateBarFrameAndPosition(for: monitor, resolved: resolved, snapshot: snapshot, instance: instance)
        return true
    }

    private func makePanel(screen: NSScreen?) -> WorkspaceBarPanel {
        let panel = panelFactory()
        panel.targetScreen = screen
        panel.onPress = { [weak self] in
            guard let self else { return }
            dragController.cancel()
            hoverPreview?.dismiss(suppressing: shellPreview?.key)
        }
        return panel
    }

    private func makeBarView(
        model: WorkspaceBarModel,
        slice: WorkspaceBarIslandSlice,
        monitorId: Monitor.ID
    ) -> WorkspaceBarView {
        WorkspaceBarView(
            model: model,
            slice: slice,
            motionPolicy: motionPolicy,
            shellSurface: { [weak self] widget in
                self?.shellSurfaceView(widget, key: ShellBarKey(monitor: monitorId, island: slice))
            },
            shaderBackground: { [weak self] in
                self?.shellHost?.barShaderView(key: ShellBarKey(monitor: monitorId, island: slice))
            }
        )
    }

    private func removeBarForMonitor(_ monitorId: Monitor.ID) {
        if let instance = barsByMonitor[monitorId] {
            if menuMonitorId == monitorId { MenuAnywhereController.shared.cancelTracking() }
            dragController.cancel()
            closeShellSystemStats(on: monitorId)
            removeSecondaryPanel(from: instance)
            surfaceCoordinator.unregister(id: instance.surfaceId())
            instance.primary.panel.orderOut(nil)
            instance.primary.panel.close()
            barsByMonitor.removeValue(forKey: monitorId)
            shellHost?.removeSurfaces(for: monitorId)
        }
    }

    func cleanup(keepingShell: Bool = false) {
        autoHideDelays.cancelAll()
        autoHideTargets = []
        handleAutoHideMouseMoved(at: .zero)
        controller?.mouseEventHandler.reconcileMouseMoveSubscription()
        notificationBadgeTargetsByMonitor.removeAll()
        hoverPreview?.dismiss()
        dragController.cancel()
        if menuMonitorId != nil { MenuAnywhereController.shared.cancelTracking() }
        menuPresenter.cancel()
        renamePanel?.dismiss()
        menuMonitorId = nil
        renameMonitorId = nil
        for monitorId in Array(barsByMonitor.keys) {
            removeBarForMonitor(monitorId)
        }
        if !keepingShell {
            stopShellHost()
        }
        syncNotificationBadges()
        menuBarHold?.update(hiding: false)
    }

    private func updateBarFrameAndPosition(
        for monitor: Monitor,
        resolved: ResolvedBarSettings,
        snapshot: WorkspaceBarSnapshot,
        instance: WorkspaceBarInstance
    ) {
        let geometry = WorkspaceBarGeometry.resolve(monitor: monitor, resolved: resolved, isVisible: true)
        var zones: WorkspaceBarZones?
        if let split = instance.splitLayout(
            geometry: geometry,
            snapshot: snapshot,
            monitor: monitor,
            resolved: resolved
        ) {
            applySplitLayout(split, resolved: resolved, instance: instance)
        } else {
            updateIslandView(instance.primary, model: instance.model, slice: .all, monitorId: instance.monitorId)
            removeSecondaryPanel(from: instance)
            let length = resolved.fullWidth ? 0 : instance.measuredLength(for: snapshot, slice: .all)
            let frame = geometry.frame(fittingLength: length, monitor: monitor, resolved: resolved)
            instance.primary.applyFrame(frame, using: frameApplier)
            zones = geometry.zones(frame: frame, monitor: monitor, resolved: resolved)
        }
        if instance.model.zones != zones {
            instance.model.zones = zones
        }
        if !resolved.systemStatsButton {
            closeShellSystemStats(on: instance.monitorId)
        }
    }

    private func updateIslandView(
        _ island: WorkspaceBarIslandPanel,
        model: WorkspaceBarModel,
        slice: WorkspaceBarIslandSlice,
        monitorId: Monitor.ID
    ) {
        guard island.slice != slice, controller != nil else { return }
        shellHost?.removeSurfaces(for: monitorId, island: island.slice)
        island.slice = slice
        island.hostingView.rootView = makeBarView(model: model, slice: slice, monitorId: monitorId)
    }
}

extension WorkspaceBarManager {
    func visibleBarFrames(on monitorId: Monitor.ID) -> [CGRect] {
        guard let instance = barsByMonitor[monitorId] else { return [] }
        return [instance.primary.panel, instance.secondary?.panel].compactMap { $0 }.filter(\.isVisible).map(\.frame)
    }

    func hiddenBarPanelPlacement(on monitorId: Monitor.ID) -> HiddenBarPanelPlacement? {
        guard let instance = barsByMonitor[monitorId], let attachment = popupAttachment(on: monitorId) else {
            return nil
        }
        let snapshot = instance.model.snapshot
        return HiddenBarPanelPlacement(
            attachment: attachment,
            visibleFrame: instance.monitor.visibleFrame,
            workspaceBar: HiddenBarPanelPlacement.WorkspaceBar(
                monitorId: monitorId,
                frame: instance.primary.panel.frame,
                backgroundStyle: snapshot.backgroundStyle,
                backgroundOpacity: snapshot.backgroundOpacity
            )
        )
    }

    func setHiddenBarJoin(_ join: HiddenBarPanelPlacement.Join?) {
        hiddenBarJoin = join
        for instance in barsByMonitor.values {
            let edge = hiddenBarJoinEdge(on: instance.monitor.id)
            if instance.model.hiddenBarJoinEdge != edge {
                instance.model.hiddenBarJoinEdge = edge
            }
        }
    }

    private func hiddenBarJoinEdge(on monitorId: Monitor.ID) -> PopupAttachment.Edge? {
        hiddenBarJoin?.monitorId == monitorId ? hiddenBarJoin?.edge : nil
    }

    func isWorkspaceBarWindow(_ window: NSWindow) -> Bool {
        barsByMonitor.values.contains {
            $0.primary.panel === window || $0.secondary?.panel === window
        }
    }

    func islandContexts(
        on monitorId: Monitor.ID
    ) -> [(instance: WorkspaceBarInstance, island: WorkspaceBarIslandPanel)] {
        guard let instance = barsByMonitor[monitorId] else { return [] }
        return [(instance, instance.primary)] + (instance.secondary.map { [(instance, $0)] } ?? [])
    }
}

extension WorkspaceBarManager {
    private func makeSecondaryPanel(
        for instance: WorkspaceBarInstance,
        resolved: ResolvedBarSettings
    ) -> WorkspaceBarIslandPanel? {
        guard controller != nil else { return nil }
        let island = WorkspaceBarIslandPanel(
            panel: makePanel(screen: screenProvider(instance.monitor.displayId)),
            rootView: makeBarView(model: instance.model, slice: .secondary, monitorId: instance.monitorId),
            resolved: resolved,
            monitor: instance.monitor
        )
        surfaceCoordinator.register(
            window: island.panel,
            id: instance.secondarySurfaceId(),
            policy: WorkspaceBarInstance.surfacePolicy
        )
        return island
    }

    private func removeSecondaryPanel(from instance: WorkspaceBarInstance) {
        guard let secondary = instance.secondary else { return }
        dragController.cancel()
        shellHost?.removeSurfaces(for: instance.monitorId, island: .secondary)
        surfaceCoordinator.unregister(id: instance.secondarySurfaceId())
        secondary.panel.orderOut(nil)
        secondary.panel.close()
        instance.secondary = nil
    }

    private func applySplitLayout(
        _ split: WorkspaceBarSplitLayout,
        resolved: ResolvedBarSettings,
        instance: WorkspaceBarInstance
    ) {
        updateIslandView(instance.primary, model: instance.model, slice: .active, monitorId: instance.monitorId)
        instance.primary.applyFrame(split.activeFrame, using: frameApplier)
        if let secondaryFrame = split.secondaryFrame,
           let secondary = instance.secondary ?? makeSecondaryPanel(for: instance, resolved: resolved)
        {
            updateIslandView(secondary, model: instance.model, slice: .secondary, monitorId: instance.monitorId)
            secondary.applyFrame(secondaryFrame, using: frameApplier)
            instance.secondary = secondary
        } else {
            removeSecondaryPanel(from: instance)
        }
    }
}

extension WorkspaceBarManager {
    func popupAttachment(on monitorId: Monitor.ID) -> PopupAttachment? {
        guard let instance = barsByMonitor[monitorId], let settings,
              instance.primary.panel.isVisible else { return nil }
        return PopupAttachment(
            sourceFrame: instance.primary.panel.frame,
            edge: settings.workspaceBar.resolved(for: instance.monitor).position.popupEdge
        )
    }
}
