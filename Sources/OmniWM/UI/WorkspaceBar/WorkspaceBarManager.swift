// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

enum WorkspaceBarWindowLevel: String, CaseIterable, Codable, Identifiable {
    case normal
    case floating
    case status
    case popup
    case screensaver

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .normal: "Normal"
        case .floating: "Floating"
        case .status: "Status Bar"
        case .popup: "Popup"
        case .screensaver: "Screen Saver"
        }
    }

    var nsWindowLevel: NSWindow.Level {
        switch self {
        case .normal: .normal
        case .floating: .floating
        case .status: .statusBar
        case .popup: .popUpMenu
        case .screensaver: .screenSaver
        }
    }
}

enum WorkspaceBarPosition: String, CaseIterable, Codable, Identifiable {
    case overlappingMenuBar
    case belowMenuBar

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .overlappingMenuBar: "Overlapping Menu Bar"
        case .belowMenuBar: "Below Menu Bar"
        }
    }
}

enum WorkspaceBarNotchMode: String, CaseIterable, Codable, Identifiable {
    case off
    case moveBelowMenuBar
    case rightOfNotch
    case splitActiveLeft
    case splitActiveRight
    case fillLeftOfNotch

    var id: String {
        rawValue
    }

    var isSplit: Bool {
        self == .splitActiveLeft || self == .splitActiveRight
    }

    var displayName: String {
        switch self {
        case .off: "Off"
        case .moveBelowMenuBar: "Move Below Menu Bar"
        case .rightOfNotch: "Right of Notch"
        case .splitActiveLeft: "Split — Active Left"
        case .splitActiveRight: "Split — Active Right"
        case .fillLeftOfNotch: "Fill Left of Notch"
        }
    }
}

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

    private var barsByMonitor: [Monitor.ID: WorkspaceBarInstance] = [:]
    private weak var controller: WMController?
    private weak var settings: SettingsStore?
    private let motionPolicy: MotionPolicy
    private let surfaceCoordinator = SurfaceCoordinator.shared

    init(motionPolicy: MotionPolicy) {
        self.motionPolicy = motionPolicy
    }

    func setup(controller: WMController, settings: SettingsStore) {
        self.controller = controller
        self.settings = settings
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
    }

    func updateAppearance() {
        guard let settings else { return }

        for instance in barsByMonitor.values {
            instance.refreshAppearance(resolved: settings.workspaceBar.resolved(for: instance.monitor))
        }
    }

    private func createBarForMonitor(_ monitor: Monitor, snapshot: WorkspaceBarSnapshot) {
        guard let controller, let settings else { return }

        let resolved = settings.workspaceBar.resolved(for: monitor)
        let model = WorkspaceBarModel(snapshot: snapshot)
        let measurementView = NSHostingView(rootView: WorkspaceBarMeasurementView(snapshot: snapshot))
        let screen = screenProvider(monitor.displayId)
        let panel = panelFactory()
        panel.targetScreen = screen
        let primary = WorkspaceBarIslandPanel(
            panel: panel,
            rootView: makeBarView(
                model: model,
                slice: .all,
                showsSystemStatsButton: snapshot.showSystemStatsButton,
                monitorId: monitor.id,
                controller: controller
            ),
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
        controller: WMController
    ) -> WorkspaceBarView {
        WorkspaceBarView(
            model: model,
            slice: slice,
            showsSystemStatsButton: showsSystemStatsButton,
            motionPolicy: motionPolicy,
            onFocusWorkspace: { [weak controller] item in
                controller?.focusWorkspaceFromBar(id: item.id)
            },
            onFocusWindow: { [weak controller] handle in
                controller?.focusWindowFromBar(handle: handle)
            },
            onActivateScratchpad: { [weak controller] index in
                guard let index = ScratchpadIndex(index) else { return }
                controller?.activateScratchpadFromBar(index: index, on: monitorId)
            },
            onToggleSystemStats: { [weak controller] in
                controller?.toggleSystemStatsFromBar(on: monitorId)
            },
            onSystemStatsAnchorChange: { [weak self] anchor in
                self?.barsByMonitor[monitorId]?.statsAnchor = anchor
            }
        )
    }

    private func removeBarForMonitor(_ monitorId: Monitor.ID) {
        if let instance = barsByMonitor[monitorId] {
            controller?.dismissSystemStatsPopup(anchoredTo: monitorId)
            removeSecondaryPanel(from: instance)
            surfaceCoordinator.unregister(id: instance.surfaceId())
            instance.primary.panel.orderOut(nil)
            instance.primary.panel.close()
            barsByMonitor.removeValue(forKey: monitorId)
        }
    }

    func cleanup() {
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
                &instance.primary,
                model: instance.model,
                slice: .all,
                showsSystemStatsButton: snapshot.showSystemStatsButton,
                monitorId: instance.monitorId
            )
            removeSecondaryPanel(from: instance)
            let width = instance.measuredWidth(
                for: snapshot,
                slice: .all,
                showsSystemStatsButton: snapshot.showSystemStatsButton
            )
            let frame = geometry.frame(fittingWidth: width, monitor: monitor, resolved: resolved)
            instance.primary.applyFrame(frame, using: frameApplier)
        }
        if !snapshot.showSystemStatsButton {
            instance.statsAnchor = nil
            controller?.dismissSystemStatsPopup(anchoredTo: instance.monitorId)
        }
    }

    func statsAnchor(on monitorId: Monitor.ID) -> CGPoint? {
        barsByMonitor[monitorId]?.statsAnchor
    }

    func primaryBarFrame(on monitorId: Monitor.ID) -> CGRect? {
        barsByMonitor[monitorId]?.primary.lastAppliedFrame
    }

    func isWorkspaceBarWindow(_ window: NSWindow) -> Bool {
        barsByMonitor.values.contains {
            $0.primary.panel === window || $0.secondary?.panel === window
        }
    }

    private func updateIslandView(
        _ island: inout WorkspaceBarIslandPanel,
        model: WorkspaceBarModel,
        slice: WorkspaceBarIslandSlice,
        showsSystemStatsButton: Bool,
        monitorId: Monitor.ID
    ) {
        guard island.slice != slice || island.showsSystemStatsButton != showsSystemStatsButton,
              let controller
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
            controller: controller
        )
    }

    private func makeSecondaryPanel(
        for instance: WorkspaceBarInstance,
        resolved: ResolvedBarSettings,
        showsSystemStatsButton: Bool
    ) -> WorkspaceBarIslandPanel? {
        guard let controller else { return nil }
        let screen = screenProvider(instance.monitor.displayId)
        let panel = panelFactory()
        panel.targetScreen = screen
        let island = WorkspaceBarIslandPanel(
            panel: panel,
            rootView: makeBarView(
                model: instance.model,
                slice: .secondary,
                showsSystemStatsButton: showsSystemStatsButton,
                monitorId: instance.monitorId,
                controller: controller
            ),
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
            &instance.primary,
            model: instance.model,
            slice: .active,
            showsSystemStatsButton: split.primaryShowsSystemStatsButton,
            monitorId: instance.monitorId
        )
        instance.primary.applyFrame(split.layout.activeFrame, using: frameApplier)
        if let secondaryFrame = split.layout.secondaryFrame,
           var secondary = instance.secondary ?? makeSecondaryPanel(
               for: instance,
               resolved: resolved,
               showsSystemStatsButton: split.secondaryShowsSystemStatsButton
           )
        {
            updateIslandView(
                &secondary,
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
