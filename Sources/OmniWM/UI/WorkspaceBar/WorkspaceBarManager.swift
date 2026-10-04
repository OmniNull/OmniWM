// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
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
    var pressTracker = WorkspaceBarPressTracker()
    let menuPresenter = WorkspaceBarMenuPresenter()
    var renamePanel: WorkspaceBarRenamePanel?
    let dragController = WorkspaceBarDragController()
    var hoverPreview: WorkspaceBarHoverPreviewController?
    let notificationBadges: WorkspaceBarBadgeService
    var notificationBadgeTargetsByMonitor: [Monitor.ID: Set<String>] = [:]
    private let motionPolicy: MotionPolicy
    private let surfaceCoordinator = SurfaceCoordinator.shared
    private var hiddenBarJoin: HiddenBarPanelPlacement.Join?

    init(motionPolicy: MotionPolicy, notificationBadges: WorkspaceBarBadgeService = WorkspaceBarBadgeService()) {
        self.motionPolicy = motionPolicy
        self.notificationBadges = notificationBadges
    }

    func setup(controller: WMController, settings: SettingsStore) {
        self.controller = controller
        self.settings = settings
        controller.hiddenBarController.onWorkspaceBarJoin = { [weak self] join in
            self?.setHiddenBarJoin(join)
        }
        configureDragController(controller: controller)
        syncHoverPreview(controller: controller, settings: settings)
    }

    func apply(_ bars: [DesiredBarSurface]) {
        guard controller != nil, settings != nil else { return }

        var staleMonitorIds = Set(barsByMonitor.keys)
        for bar in bars where bar.visible {
            staleMonitorIds.remove(bar.monitor.id)
            if let existing = barsByMonitor[bar.monitor.id] {
                if !updateBarForMonitor(bar.monitor, snapshot: bar.snapshot, instance: existing) {
                    removeBarForMonitor(bar.monitor.id)
                    createBarForMonitor(bar.monitor, snapshot: bar.snapshot)
                }
            } else {
                createBarForMonitor(bar.monitor, snapshot: bar.snapshot)
            }
        }

        for monitorId in staleMonitorIds {
            removeBarForMonitor(monitorId)
        }
        updateNotificationBadgeTargets(bars)
        dragController.barsDidUpdate()
        hoverPreview?.targetsDidChange { [weak self] key in
            self?.hoverTarget(for: key)
        }
        controller?.hiddenBarController.updatePanelPlacement(hiddenBarPanelPlacement(on:))
    }

    func updateAppearance() {
        guard let settings else { return }

        for instance in barsByMonitor.values {
            instance.refreshAppearance(resolved: settings.workspaceBar.resolved(for: instance.monitor))
        }
    }

    private func createBarForMonitor(_ monitor: Monitor, snapshot: WorkspaceBarSnapshot) {
        guard controller != nil, let settings else { return }

        let resolved = settings.workspaceBar.resolved(for: monitor)
        let model = WorkspaceBarModel(snapshot: snapshot)
        model.hiddenBarJoinEdge = hiddenBarJoinEdge(on: monitor.id)
        let measurementView = NSHostingView(rootView: WorkspaceBarMeasurementView(snapshot: snapshot))
        let screen = screenProvider(monitor.displayId)
        let panel = panelFactory()
        panel.targetScreen = screen
        let interaction = makeIslandInteraction(panel: panel, monitorId: monitor.id)
        let primary = WorkspaceBarIslandPanel(
            panel: panel,
            rootView: makeBarView(
                model: model,
                slice: .all,
                showsSystemStatsButton: snapshot.showSystemStatsButton,
                monitorId: monitor.id,
                interaction: interaction
            ),
            interaction: interaction,
            resolved: resolved
        )

        let instance = WorkspaceBarInstance(
            monitor: monitor,
            primary: primary,
            measurementView: measurementView,
            model: model,
            screenDisplayId: screen?.displayId
        )
        let preparedSnapshot = instance.scratchpadCompactedSnapshot(
            snapshot,
            monitor: monitor,
            resolved: resolved
        )
        model.snapshot = preparedSnapshot
        barsByMonitor[monitor.id] = instance

        instance.applyCurrentAppearance()
        updateBarFrameAndPosition(
            for: monitor,
            resolved: resolved,
            snapshot: preparedSnapshot,
            instance: instance
        )
        surfaceCoordinator.register(
            window: primary.panel,
            id: instance.surfaceId(),
            policy: WorkspaceBarInstance.surfacePolicy
        )
        primary.panel.orderFrontRegardless()
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
        let preparedSnapshot = instance.scratchpadCompactedSnapshot(
            snapshot,
            monitor: monitor,
            resolved: resolved
        )
        instance.updateSnapshot(preparedSnapshot)
        instance.applyCurrentAppearance()
        instance.applyPanelSettings(resolved: resolved)
        updateBarFrameAndPosition(
            for: monitor,
            resolved: resolved,
            snapshot: preparedSnapshot,
            instance: instance
        )
        return true
    }

    private func makeBarView(
        model: WorkspaceBarModel,
        slice: WorkspaceBarIslandSlice,
        showsSystemStatsButton: Bool,
        monitorId: Monitor.ID,
        interaction: WorkspaceBarIslandInteraction
    ) -> WorkspaceBarView {
        WorkspaceBarView(
            model: model,
            slice: slice,
            showsSystemStatsButton: showsSystemStatsButton,
            motionPolicy: motionPolicy,
            onFocusWorkspace: { [weak self] item in
                self?.controller?.focusWorkspaceFromBar(id: item.id)
            },
            onFocusWindow: { [weak self] handle in
                self?.controller?.focusWindowFromBar(handle: handle)
            },
            onActivateScratchpad: { [weak self] index in
                guard let index = ScratchpadIndex(index) else { return }
                self?.controller?.activateScratchpadFromBar(index: index, on: monitorId)
            },
            onOmniWMClick: { [weak self] anchor, event in
                guard let self, let instance = barsByMonitor[monitorId], let settings else { return }
                controller?.statusBarController?.routeClick(
                    event: event,
                    anchor: anchor,
                    edge: settings.workspaceBar.resolved(for: instance.monitor).position.popupEdge,
                    monitorId: monitorId
                )
            },
            onToggleSystemStats: { [weak self] in
                self?.controller?.toggleSystemStatsFromBar(on: monitorId)
            },
            onSystemStatsAnchorChange: { [weak self] anchor in
                self?.barsByMonitor[monitorId]?.statsAnchorView = anchor
            },
            interaction: interaction,
            dragPresentation: dragController.presentation,
            notificationBadges: notificationBadges
        )
    }

    private func removeBarForMonitor(_ monitorId: Monitor.ID) {
        if let instance = barsByMonitor[monitorId] {
            dragController.cancel()
            pressTracker.reset()
            controller?.dismissSystemStatsPopup(anchoredTo: monitorId)
            removeSecondaryPanel(from: instance)
            surfaceCoordinator.unregister(id: instance.surfaceId())
            instance.primary.panel.orderOut(nil)
            instance.primary.panel.close()
            barsByMonitor.removeValue(forKey: monitorId)
        }
    }

    func cleanup() {
        notificationBadges.stop()
        notificationBadgeTargetsByMonitor.removeAll()
        hoverPreview?.dismiss()
        dragController.cancel()
        menuPresenter.cancel()
        renamePanel?.dismiss()
        pressTracker.reset()
        for monitorId in Array(barsByMonitor.keys) {
            removeBarForMonitor(monitorId)
        }
    }

    private func updateBarFrameAndPosition(
        for monitor: Monitor,
        resolved: ResolvedBarSettings,
        snapshot: WorkspaceBarSnapshot,
        instance: WorkspaceBarInstance
    ) {
        let geometry = WorkspaceBarGeometry.resolve(monitor: monitor, resolved: resolved, isVisible: true)
        if let split = instance.splitLayout(
            geometry: geometry,
            snapshot: snapshot,
            monitor: monitor,
            resolved: resolved
        ) {
            applySplitLayout(split, resolved: resolved, instance: instance)
        } else {
            updateIslandView(
                instance.primary,
                model: instance.model,
                slice: .all,
                showsSystemStatsButton: snapshot.showSystemStatsButton,
                monitorId: instance.monitorId
            )
            removeSecondaryPanel(from: instance)
            let length = instance.measuredLength(
                for: snapshot,
                slice: .all,
                showsSystemStatsButton: snapshot.showSystemStatsButton
            )
            let frame = geometry.frame(fittingLength: length, monitor: monitor, resolved: resolved)
            instance.primary.applyFrame(frame, using: frameApplier)
        }
        if !snapshot.showSystemStatsButton {
            instance.statsAnchorView = nil
            controller?.dismissSystemStatsPopup(anchoredTo: instance.monitorId)
        }
    }

    private func updateIslandView(
        _ island: WorkspaceBarIslandPanel,
        model: WorkspaceBarModel,
        slice: WorkspaceBarIslandSlice,
        showsSystemStatsButton: Bool,
        monitorId: Monitor.ID
    ) {
        guard island.slice != slice || island.showsSystemStatsButton != showsSystemStatsButton,
              controller != nil
        else {
            return
        }
        island.slice = slice
        island.showsSystemStatsButton = showsSystemStatsButton
        island.hostingView.rootView = makeBarView(
            model: model,
            slice: slice,
            showsSystemStatsButton: showsSystemStatsButton,
            monitorId: monitorId,
            interaction: island.interaction
        )
    }
}

extension WorkspaceBarManager {
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

    func statsAnchor(on monitorId: Monitor.ID) -> CGPoint? {
        guard let view = barsByMonitor[monitorId]?.statsAnchorView, let window = view.window else { return nil }
        let frame = window.convertToScreen(view.convert(view.bounds, to: nil))
        return WorkspaceBarGeometry.statsButtonAnchor(buttonFrame: frame)
    }

    func isWorkspaceBarWindow(_ window: NSWindow) -> Bool {
        barsByMonitor.values.contains {
            $0.primary.panel === window || $0.secondary?.panel === window
        }
    }

    func islandContext(
        for panel: WorkspaceBarPanel
    ) -> (instance: WorkspaceBarInstance, island: WorkspaceBarIslandPanel)? {
        for instance in barsByMonitor.values {
            if instance.primary.panel === panel {
                return (instance, instance.primary)
            }
            if let secondary = instance.secondary, secondary.panel === panel {
                return (instance, secondary)
            }
        }
        return nil
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
        resolved: ResolvedBarSettings,
        showsSystemStatsButton: Bool
    ) -> WorkspaceBarIslandPanel? {
        guard controller != nil else { return nil }
        let screen = screenProvider(instance.monitor.displayId)
        let panel = panelFactory()
        panel.targetScreen = screen
        let interaction = makeIslandInteraction(panel: panel, monitorId: instance.monitorId)
        let island = WorkspaceBarIslandPanel(
            panel: panel,
            rootView: makeBarView(
                model: instance.model,
                slice: .secondary,
                showsSystemStatsButton: showsSystemStatsButton,
                monitorId: instance.monitorId,
                interaction: interaction
            ),
            interaction: interaction,
            resolved: resolved
        )
        surfaceCoordinator.register(
            window: island.panel,
            id: instance.secondarySurfaceId(),
            policy: WorkspaceBarInstance.surfacePolicy
        )
        island.panel.orderFrontRegardless()
        return island
    }

    private func removeSecondaryPanel(from instance: WorkspaceBarInstance) {
        guard let secondary = instance.secondary else { return }
        dragController.cancel()
        surfaceCoordinator.unregister(id: instance.secondarySurfaceId())
        secondary.panel.orderOut(nil)
        secondary.panel.close()
        instance.secondary = nil
    }

    private func applySplitLayout(
        _ split: WorkspaceBarInstance.SplitLayoutResult,
        resolved: ResolvedBarSettings,
        instance: WorkspaceBarInstance
    ) {
        updateIslandView(
            instance.primary,
            model: instance.model,
            slice: .active,
            showsSystemStatsButton: split.primaryShowsSystemStatsButton,
            monitorId: instance.monitorId
        )
        instance.primary.applyFrame(split.layout.activeFrame, using: frameApplier)
        if let secondaryFrame = split.layout.secondaryFrame,
           let secondary = instance.secondary ?? makeSecondaryPanel(
               for: instance,
               resolved: resolved,
               showsSystemStatsButton: split.secondaryShowsSystemStatsButton
           )
        {
            updateIslandView(
                secondary,
                model: instance.model,
                slice: .secondary,
                showsSystemStatsButton: split.secondaryShowsSystemStatsButton,
                monitorId: instance.monitorId
            )
            secondary.applyFrame(secondaryFrame, using: frameApplier)
            instance.secondary = secondary
        } else {
            removeSecondaryPanel(from: instance)
        }
    }
}

extension WorkspaceBarManager {
    func popupAttachment(on monitorId: Monitor.ID, forStats: Bool = false) -> PopupAttachment? {
        guard let instance = barsByMonitor[monitorId], let settings,
              let window = forStats ? instance.statsAnchorView?.window : instance.primary.panel
        else { return nil }
        let edge = settings.workspaceBar.resolved(for: instance.monitor).position.popupEdge
        return PopupAttachment(
            sourceFrame: window.frame, edge: edge,
            alignment: forStats ? statsAnchor(on: monitorId) : nil
        )
    }
}
