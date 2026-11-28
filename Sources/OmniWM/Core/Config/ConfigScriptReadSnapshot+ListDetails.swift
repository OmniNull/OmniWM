// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMScriptHost

struct ScriptWorkspaceDetailContext {
    let session: ConfigScriptSession
    let engine: NiriLayoutEngine?
    let focusedToken: WindowToken?
    let focusedWorkspaceId: WorkspaceDescriptor.ID?
    let currentWorkspaceId: WorkspaceDescriptor.ID?
    let visibleWorkspaceIds: Set<WorkspaceDescriptor.ID>
}

struct ScriptMonitorDetailContext {
    let currentMonitorId: Monitor.ID?
}

struct ScriptNiriGeometry {
    let monitor: Monitor.ID
    let geometry: NiriSizingGeometry
}

extension WMController {
    func scriptWorkspaceDetailContext(session: ConfigScriptSession) -> ScriptWorkspaceDetailContext {
        let manager = workspaceManager
        let focusedToken = manager.nativeManagedFocusToken
        return ScriptWorkspaceDetailContext(
            session: session,
            engine: manager.niriEngine,
            focusedToken: focusedToken,
            focusedWorkspaceId: focusedToken.flatMap { manager.workspace(for: $0) },
            currentWorkspaceId: manager.interactionMonitorID().flatMap { manager.visibleWorkspaceId(on: $0) },
            visibleWorkspaceIds: manager.visibleWorkspaceIds()
        )
    }

    func scriptMonitorDetailContext() -> ScriptMonitorDetailContext {
        let manager = workspaceManager
        let current = manager.interactionMonitorId ?? manager.interactionMonitorID()
        return ScriptMonitorDetailContext(currentMonitorId: current)
    }

    func writeScriptWorkspaceDetails(
        _ workspace: borrowing WorkspaceDescriptor, on monitor: Monitor.ID?,
        context: borrowing ScriptWorkspaceDetailContext, scratch: inout ConfigScriptReadScratch,
        to row: inout ConfigScriptSnapshotWriter
    ) -> Bool {
        let id = workspace.id
        let niri = settings.workspaces.configScriptLayout(for: workspace.name) == .niri
        let state = niri ? workspaceManager.niriViewportState(for: id) : nil
        var columns = false
        if let state {
            columns = indexScriptViewportColumns(
                in: id, on: monitor, state: state, engine: context.engine, scratch: &scratch
            )
        }
        let flags = Self.scriptWorkspaceDetailFlags(id, niri: niri, columns: columns, context: context)
        guard row.string(settings.workspaces.configScriptDisplayName(for: workspace.name)),
              row.detailValue(Self.scriptWorkspaceNumber(workspace.name)), row.flag(flags),
              writeScriptWindowCounts(in: id, scratch: &scratch, to: &row)
        else { return false }
        if context.focusedWorkspaceId == id, let token = context.focusedToken {
            guard row.windowID(token, session: context.session) else { return false }
        } else if !row.string(String?.none) {
            return false
        }
        guard let state else { return true }
        guard row.detailNumber(state.viewOffset) else { return false }
        return !columns || writeScriptViewportColumns(scratch: scratch, to: &row)
    }

    private static func scriptWorkspaceDetailFlags(
        _ id: WorkspaceDescriptor.ID, niri: Bool, columns: Bool, context: borrowing ScriptWorkspaceDetailContext
    ) -> UInt8 {
        var flags = context.visibleWorkspaceIds.contains(id) ? OMNI_CONFIG_WORKSPACE_DETAIL_VISIBLE : 0
        if context.focusedWorkspaceId == id { flags |= OMNI_CONFIG_WORKSPACE_DETAIL_FOCUSED }
        if context.currentWorkspaceId == id { flags |= OMNI_CONFIG_WORKSPACE_DETAIL_CURRENT }
        if !niri { flags |= OMNI_CONFIG_WORKSPACE_DETAIL_DWINDLE }
        if columns { flags |= OMNI_CONFIG_WORKSPACE_DETAIL_COLUMNS }
        return UInt8(flags)
    }

    static func scriptWorkspaceNumber(_ name: String) -> UInt64 {
        guard let first = name.utf8.first, first >= UInt8(ascii: "1"), first <= UInt8(ascii: "9"),
              let number = UInt64(name), number <= OMNI_CONFIG_MAX_SAFE_INTEGER
        else { return 0 }
        return number
    }

    private func writeScriptWindowCounts(
        in workspaceId: WorkspaceDescriptor.ID, scratch: inout ConfigScriptReadScratch,
        to row: inout ConfigScriptSnapshotWriter
    ) -> Bool {
        let windows = workspaceManager.windowQueries
        var total: UInt32 = 0
        var tiled: UInt32 = 0
        var floating: UInt32 = 0
        var scratchpad: UInt32 = 0
        windows.forEachToken(in: workspaceId) { token in
            total += 1
            switch windows.mode(for: token) {
            case .tiling: tiled += 1
            case .floating: floating += 1
            case nil: break
            }
            if scratch.scratchpadSlots[token] != nil { scratchpad += 1 }
        }
        return row.detailValue(total) && row.detailValue(tiled) && row.detailValue(floating)
            && row.detailValue(scratchpad)
    }

    private func indexScriptViewportColumns(
        in workspaceId: WorkspaceDescriptor.ID, on monitorId: Monitor.ID?, state: ViewportState,
        engine: NiriLayoutEngine?, scratch: inout ConfigScriptReadScratch
    ) -> Bool {
        guard let engine, let monitorId, let geometry = scriptNiriGeometry(on: monitorId, scratch: &scratch) else {
            return false
        }
        let columns = engine.projectedColumns(in: workspaceId)
        engine.viewportRelations(
            of: columns,
            in: workspaceId,
            state: state,
            geometry: geometry,
            into: &scratch.viewport
        )
        scratch.tabbedColumns.removeAll(keepingCapacity: true)
        let projected = columns.span
        for index in projected.indices {
            scratch.tabbedColumns.append(projected[index].column.displayMode == .tabbed)
        }
        return true
    }

    private func scriptNiriGeometry(
        on monitorId: Monitor.ID, scratch: inout ConfigScriptReadScratch
    ) -> NiriSizingGeometry? {
        for index in scratch.geometries.indices where scratch.geometries[index].monitor == monitorId {
            return scratch.geometries[index].geometry
        }
        guard let monitor = workspaceManager.monitor(byId: monitorId) else { return nil }
        let interaction = niriInteractionGeometry(for: monitor, scale: monitor.backingScale)
        let geometry = NiriSizingGeometry(
            workingFrame: interaction.workingFrame, gaps: interaction.innerGap,
            orientation: settings.monitors.effectiveOrientation(for: monitor)
        )
        scratch.geometries.append(ScriptNiriGeometry(monitor: monitorId, geometry: geometry))
        return geometry
    }

    private func writeScriptViewportColumns(
        scratch: borrowing ConfigScriptReadScratch, to row: inout ConfigScriptSnapshotWriter
    ) -> Bool {
        let relations = scratch.viewport.relations.span
        let tabbed = scratch.tabbedColumns.span
        guard row.count(UInt16(clamping: relations.count)) else { return false }
        for index in relations.indices {
            let viewport: UInt32 = switch relations[index] {
            case .before: OMNI_CONFIG_COLUMN_VIEWPORT_BEFORE
            case .intersecting: OMNI_CONFIG_COLUMN_VIEWPORT_INTERSECTING
            case .after: OMNI_CONFIG_COLUMN_VIEWPORT_AFTER
            }
            let mode = tabbed[index] ? OMNI_CONFIG_COLUMN_TABBED : 0
            guard row.flag(UInt8(mode | viewport << OMNI_CONFIG_COLUMN_VIEWPORT_SHIFT)) else { return false }
        }
        return true
    }

    func writeScriptMonitorDetails(
        _ monitor: borrowing Monitor, context: borrowing ScriptMonitorDetailContext,
        to row: inout ConfigScriptSnapshotWriter
    ) -> Bool {
        let gaps = settings.gaps.resolved(for: monitor)
        let flags = scriptMonitorDetailFlags(monitor, context: context, fullscreenGaps: gaps.fullscreenUsesOuterGaps)
        guard row.flag(flags), row.string(monitor.displayUUID) else { return false }
        if let notch = monitor.notchRange {
            guard row.detailNumber(notch.lowerBound), row.detailNumber(notch.upperBound) else { return false }
        }
        let insets = workspaceBarReservedInsets(for: monitor)
        let bars = workspaceBarManager.shownBarFrames[monitor.id] ?? WorkspaceBarShownFrames()
        guard row.detailNumber(gaps.innerGap),
              row.detailEdges(gaps.outerGapLeft, gaps.outerGapRight, gaps.outerGapTop, gaps.outerGapBottom),
              row.detailNumber(max(0, monitor.frame.maxY - monitor.visibleFrame.maxY)),
              row.detailEdges(insets.left, insets.right, insets.top, insets.bottom), row.flag(UInt8(bars.count))
        else { return false }
        return (bars.primary.map { row.detailRect($0) } ?? true) && (bars.secondary.map { row.detailRect($0) } ?? true)
    }

    private func scriptMonitorDetailFlags(
        _ monitor: borrowing Monitor, context: borrowing ScriptMonitorDetailContext, fullscreenGaps: Bool
    ) -> UInt8 {
        var flags = monitor.isMain ? OMNI_CONFIG_MONITOR_DETAIL_MAIN : 0
        if context.currentMonitorId == monitor.id { flags |= OMNI_CONFIG_MONITOR_DETAIL_CURRENT }
        if monitor.hasNotch { flags |= OMNI_CONFIG_MONITOR_DETAIL_HAS_NOTCH }
        if monitor.notchRange != nil { flags |= OMNI_CONFIG_MONITOR_DETAIL_NOTCH }
        if settings.monitors.effectiveOrientation(for: monitor) == .vertical {
            flags |= OMNI_CONFIG_MONITOR_DETAIL_VERTICAL
        }
        if fullscreenGaps { flags |= OMNI_CONFIG_MONITOR_DETAIL_FULLSCREEN_OUTER_GAPS }
        return UInt8(flags)
    }
}
