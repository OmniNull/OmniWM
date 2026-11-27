// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMScriptHost

struct ConfigScriptReadScratch {
    var columns = ConfigScriptColumnIndex()
    var focusRanks: [WindowToken: Int] = [:]
    var scratchpadSlots: [WindowToken: Int] = [:]
    var columnDetails = ConfigScriptColumnDetailsIndex()
    var viewport = NiriViewportScratch()
    var tabbedColumns: [Bool] = []
    var geometries: [ScriptNiriGeometry] = []

    mutating func beginListDetails() {
        geometries.removeAll(keepingCapacity: true)
        viewport.recollectPlacementMonitors()
    }
}

struct ScriptWindowDetailIndexes {
    let focusRank: Int?
    let scratchpadSlot: Int?
}

struct ConfigScriptColumnDetail {
    let position: UInt32
    let size: UInt32
    let span: Double
}

struct ConfigScriptColumnDetailsIndex {
    private var rows: [WindowToken: ConfigScriptColumnDetail] = [:]
    private var members: [NiriWindow] = []

    subscript(token: WindowToken) -> ConfigScriptColumnDetail? {
        rows[token]
    }

    mutating func reset() {
        rows.removeAll(keepingCapacity: true)
    }

    mutating func index(
        _ root: NiriRoot, engine: NiriLayoutEngine, geometry: NiriSizingGeometry
    ) {
        let membership = engine.projectionMembership(in: root.workspaceId)
        indexProjected(root.projectedColumns, membership: membership, engine: engine, geometry: geometry)
    }

    private mutating func indexProjected(
        _ columns: borrowing [NiriProjectedColumn], membership: borrowing NiriProjectionMembership,
        engine: NiriLayoutEngine, geometry: NiriSizingGeometry
    ) {
        let projected = columns.span
        let hasExclusions = !membership.admitsEveryWindow
        for slot in projected.indices where !projected[slot].windows.isEmpty {
            if hasExclusions, let first = firstExcludedMember(in: projected[slot].windows, membership: membership) {
                indexFiltered(projected[slot], from: first, excluding: membership, geometry: geometry, engine: engine)
                continue
            }
            Self.indexMembers(
                projected[slot].column, windows: projected[slot].windows.span,
                engine: engine, geometry: geometry, into: &rows
            )
        }
    }

    private func firstExcludedMember(
        in windows: borrowing [NiriWindow], membership: borrowing NiriProjectionMembership
    ) -> Int? {
        let windows = windows.span
        for offset in windows.indices where !membership.admits(windows[offset].token) {
            return offset
        }
        return nil
    }

    private mutating func indexFiltered(
        _ column: borrowing NiriProjectedColumn, from first: Int,
        excluding membership: borrowing NiriProjectionMembership,
        geometry: NiriSizingGeometry, engine: NiriLayoutEngine
    ) {
        let windows = column.windows.span
        for offset in 0 ..< first { members.append(windows[offset]) }
        for offset in (first + 1) ..< windows.count where membership.admits(windows[offset].token) {
            members.append(windows[offset])
        }
        if !members.isEmpty {
            Self.indexMembers(
                column.column, windows: members.span, engine: engine, geometry: geometry,
                into: &rows, fullMembership: false
            )
            members.removeAll(keepingCapacity: true)
        }
    }

    private static func indexMembers(
        _ column: borrowing NiriContainer, windows: borrowing Span<NiriWindow>,
        engine: NiriLayoutEngine, geometry: NiriSizingGeometry,
        into rows: inout [WindowToken: ConfigScriptColumnDetail], fullMembership: Bool = true
    ) {
        let axis = geometry.orientation == .horizontal ? geometry.workingFrame.width : geometry.workingFrame.height
        let span = Double(engine.settledPrimarySpan(
            of: column, windows: windows, geometry: geometry, fullMembership: fullMembership
        ) / axis)
        let size = UInt32(clamping: windows.count)
        for offset in windows.indices {
            rows[windows[offset].token] = ConfigScriptColumnDetail(
                position: UInt32(clamping: offset + 1), size: size, span: span
            )
        }
    }
}

extension WMController {
    func indexScriptColumnDetails(
        in workspaceId: WorkspaceDescriptor.ID, monitorId: Monitor.ID?, engine: NiriLayoutEngine?,
        into index: inout ConfigScriptColumnDetailsIndex
    ) {
        index.reset()
        guard let engine, let root = engine.root(for: workspaceId),
              let monitorId, let monitor = workspaceManager.monitor(byId: monitorId) else { return }
        let interaction = niriInteractionGeometry(for: monitor, scale: monitor.backingScale)
        let orientation = settings.monitors.effectiveOrientation(for: monitor)
        let geometry = NiriSizingGeometry(
            workingFrame: interaction.workingFrame, gaps: interaction.innerGap, orientation: orientation
        )
        let axis = orientation == .horizontal ? geometry.workingFrame.width : geometry.workingFrame.height
        guard axis > 0 else { return }
        index.index(root, engine: engine, geometry: geometry)
    }

    func writeScriptWindowDetails(
        _ entry: borrowing WindowState, workspaceShown: Bool, indexes: ScriptWindowDetailIndexes,
        column: ConfigScriptColumnDetail?, to row: inout ConfigScriptSnapshotWriter
    ) -> Bool {
        let slot = UInt32(clamping: indexes.scratchpadSlot ?? Int(UInt32.max))
        let rank = UInt32(clamping: indexes.focusRank ?? Int(UInt32.max))
        guard row.detailValue(UInt32(bitPattern: entry.pid)),
              row.detailValue(UInt32(truncatingIfNeeded: entry.windowId)),
              writeScriptAppName(entry, to: &row),
              row.detailValue(scriptDetailFlags(entry, workspaceShown: workspaceShown)),
              row.detailValue(slot), row.detailValue(rank)
        else { return false }

        guard entry.mode == .tiling, let column else { return row.detailValue(UInt32.zero) }
        return row.detailValue(column.position) && row.detailValue(column.size) && row
            .detailValue(column.span.bitPattern)
    }

    private func scriptDetailFlags(_ entry: borrowing WindowState, workspaceShown: Bool) -> UInt8 {
        let appHidden = workspaceManager.isAppHidden(pid: entry.pid)
        let visible = entry.isModelVisible(workspaceShown: workspaceShown, appHidden: appHidden)
        let layout = entry.layoutReason == .standard ? 0 : OMNI_CONFIG_DETAIL_NATIVE_FULLSCREEN
        let override: UInt32 = switch entry.manualLayoutOverride {
        case .forceTile: OMNI_CONFIG_DETAIL_FORCE_TILE
        case .forceFloat: OMNI_CONFIG_DETAIL_FORCE_FLOAT
        case nil: 0
        }
        let hidden = scriptHiddenReason(entry) << OMNI_CONFIG_DETAIL_HIDDEN_SHIFT
        return UInt8(layout | override | hidden | (visible ? OMNI_CONFIG_DETAIL_VISIBLE : 0)
            | (appHidden ? OMNI_CONFIG_DETAIL_APP_HIDDEN : 0))
    }

    private func writeScriptAppName(_ entry: borrowing WindowState, to row: inout ConfigScriptSnapshotWriter) -> Bool {
        if case let .hosted(hosted) = entry.target { return row.string(hosted.title) }
        return appInfoCache.withCachedName(for: entry.pid) { row.string($0) }
    }

    private func scriptHiddenReason(_ entry: borrowing WindowState) -> UInt32 {
        switch entry.hiddenState?.reason {
        case .workspaceInactive: OMNI_CONFIG_DETAIL_WORKSPACE_INACTIVE
        case .layoutTransient:
            workspaceManager.isInactiveTabMember(entry.token, in: entry.workspaceId)
                ? OMNI_CONFIG_DETAIL_TAB_INACTIVE : OMNI_CONFIG_DETAIL_LAYOUT_TRANSIENT
        case .scratchpad: OMNI_CONFIG_DETAIL_SCRATCHPAD
        case nil: 0
        }
    }
}
