// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import OmniWMIPC

extension WMController {
    func updateMonitorOrientations() {
        var orientations: [Monitor.ID: Monitor.Orientation] = [:]
        for monitor in workspaceManager.monitors {
            orientations[monitor.id] = settings.monitors.effectiveOrientation(for: monitor)
        }
        workspaceManager.withEngineMutationScope {
            niriEngine?.updateMonitorOrientations(orientations)
        }
        layoutRefreshController.requestRelayout(reason: .monitorSettingsChanged)
    }

    func updateMonitorNiriSettings() {
        guard niriEngine != nil else { return }
        niriLayoutHandler.refreshResolvedMonitorSettings()
        layoutRefreshController.requestRelayout(reason: .monitorSettingsChanged)
    }

    func updateMonitorDwindleSettings() {
        guard dwindleEngine != nil else { return }
        workspaceManager.invalidateAllLayouts()
        layoutRefreshController.requestRelayout(reason: .monitorSettingsChanged)
    }

    func updateMonitorGapSettings() {
        workspaceManager.invalidateAllLayouts()
        layoutRefreshController.requestRelayout(reason: .monitorSettingsChanged)
        publishDisplayChanged()
    }

    func publishDisplayChanged() {
        guard let ipcApplicationBridge else { return }
        Task {
            await ipcApplicationBridge.publishEvent(.displayChanged)
        }
    }

    func updateWorkspaceConfig() {
        workspaceManager.applySettings()
        syncMonitorsToNiriEngine()
        layoutRefreshController.requestRelayout(reason: .workspaceConfigChanged)
    }

    func rebuildAppRulesCache() {
        windowRuleEngine.rebuild(rules: settings.appRules)
    }

    func updateAppRules() {
        rebuildAppRulesCache()
        layoutRefreshController.requestFullRescan(reason: .appRulesChanged)
    }

    func enableNiriLayout(
        centerFocusedColumn: CenterFocusedColumn = .never,
        alwaysCenterSingleColumn: Bool = false
    ) {
        niriLayoutHandler.enableNiriLayout(
            centerFocusedColumn: centerFocusedColumn,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn
        )
    }

    func syncMonitorsToNiriEngine() {
        niriLayoutHandler.syncMonitorsToNiriEngine()
    }

    func updateNiriConfig(
        visibleContainerCount: Int? = nil,
        infiniteLoop: Bool? = nil,
        centerFocusedColumn: CenterFocusedColumn? = nil,
        alwaysCenterSingleColumn: Bool? = nil,
        singleWindowFit: SingleWindowFit? = nil,
        containerPrimarySpanPresets: [Double]? = nil,
        defaultContainerPrimarySpan: Double?? = nil
    ) {
        niriLayoutHandler.updateNiriConfig(
            visibleContainerCount: visibleContainerCount,
            infiniteLoop: infiniteLoop,
            centerFocusedColumn: centerFocusedColumn,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn,
            singleWindowFit: singleWindowFit,
            containerPrimarySpanPresets: containerPrimarySpanPresets,
            defaultContainerPrimarySpan: defaultContainerPrimarySpan
        )
    }

    func balanceNiriSizesAllWorkspaces() {
        niriLayoutHandler.balanceSizesAllWorkspaces()
    }

    func enableDwindleLayout() {
        dwindleLayoutHandler.enableDwindleLayout()
    }

    func updateDwindleConfig(
        smartSplit: Bool? = nil,
        defaultSplitRatio: CGFloat? = nil,
        splitWidthMultiplier: CGFloat? = nil,
        singleWindowFit: SingleWindowFit? = nil,
        innerGap: CGFloat? = nil,
        stackIncomingWindows: Bool? = nil
    ) {
        dwindleLayoutHandler.updateDwindleConfig(
            smartSplit: smartSplit,
            defaultSplitRatio: defaultSplitRatio,
            splitWidthMultiplier: splitWidthMultiplier,
            singleWindowFit: singleWindowFit,
            innerGap: innerGap,
            stackIncomingWindows: stackIncomingWindows
        )
    }

    var niriEngine: NiriLayoutEngine? {
        get { workspaceManager.niriEngine }
        set { workspaceManager.niriEngine = newValue }
    }

    var dwindleEngine: DwindleLayoutEngine? {
        get { workspaceManager.dwindleEngine }
        set {
            if let current = workspaceManager.dwindleEngine, current !== newValue {
                layoutRefreshController.stopAllDwindleAnimations()
            }
            workspaceManager.dwindleEngine = newValue
        }
    }
}
