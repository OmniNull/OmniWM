// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMScriptHost

struct ConfigScriptSnapshot: Sendable {
    static let rowLimit = 256
    static let byteLimit = 128 * 1024
    static let detailByteLimit = 16 * 1024
    static let windowFrameBytes = MemoryLayout<UInt8>.size + MemoryLayout<CGRect>.size
    static let monitorFrameBytes = 2 * MemoryLayout<CGRect>.size
    static let columnBytes = MemoryLayout<UInt16>.size
    fileprivate let reservation: ConfigScriptSnapshotPool.Reservation
    fileprivate let bytes: [UInt8]

    func withUnsafeBytes<R>(_ read: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try withExtendedLifetime(reservation) { try bytes.withUnsafeBytes(read) }
    }

    #if DEBUG || OMNIWM_CONFIG_CALLBACK_TRACE
        @MainActor static var captures = 0
    #endif

    #if OMNIWM_CONFIG_CALLBACK_TRACE
        @MainActor static var capturedLists = 0
        @MainActor static var capturedRows = 0
    #endif
}

@MainActor
struct ConfigScriptSnapshotPool {
    fileprivate final class Reservation: Sendable {}

    private struct Slot {
        var reservation = Reservation()
        var storage: [UInt8] = []
    }

    private var slots: [Slot] = []
    private var capacityHints: [UInt32: Int] = [:]
    private var scratch = ConfigScriptReadScratch()

    fileprivate mutating func capture(
        reads: ConfigScriptReads, write: (inout ConfigScriptSnapshotWriter, inout ConfigScriptReadScratch) -> Void
    ) -> ConfigScriptSnapshot {
        var index = slots.startIndex
        while index < slots.endIndex, !isKnownUniquelyReferenced(&slots[index].reservation) {
            index += 1
        }
        if index == slots.endIndex { slots.append(Slot()) }
        let sections = reads.intersection(.sections).rawValue.nonzeroBitCount
        let limit = sections * ConfigScriptSnapshot.byteLimit + reads.frameByteLimit + reads.columnByteLimit + reads
            .detailByteLimit
        var output = ConfigScriptSnapshotWriter(limit: limit)
        swap(&slots[index].storage, &output.bytes)
        output.bytes.removeAll(keepingCapacity: true)
        let capacity = capacityHints[reads.rawValue] ?? 0
        output.bytes.reserveCapacity(capacity == 0 ? limit : capacity)
        write(&output, &scratch)
        if output.bytes.count > capacity { capacityHints[reads.rawValue] = output.bytes.count }
        swap(&slots[index].storage, &output.bytes)
        return ConfigScriptSnapshot(reservation: slots[index].reservation, bytes: slots[index].storage)
    }
}

private struct ScriptReadOrigin {
    let workspaceId: WorkspaceDescriptor.ID?
    let token: WindowToken?
    let session: ConfigScriptSession
}

private struct ScriptStrip {
    let node: NiriContainer
    let membership: NiriProjectionMembership
    let column: UInt16
    let columns: UInt16
    let members: UInt16
    let vertical: Bool
}

extension WMController {
    func configScriptSnapshot(
        reads: ConfigScriptReads, target: borrowing ConfigScriptTarget, pool: inout ConfigScriptSnapshotPool
    ) -> ConfigScriptSnapshot {
        let origin = ScriptReadOrigin(workspaceId: target.workspaceId, token: target.token, session: target.sessionID)
        return pool.capture(reads: reads) { writeSnapshot(reads: reads, origin: origin, to: &$0, scratch: &$1) }
    }

    private func writeSnapshot(
        reads: ConfigScriptReads, origin: ScriptReadOrigin, to output: inout ConfigScriptSnapshotWriter,
        scratch: inout ConfigScriptReadScratch
    ) {
        let manager = workspaceManager
        let session = origin.session
        lazy var resolution = manager.monitorResolutionContext()
        if !reads.isDisjoint(with: .windowDetailSections) {
            manager.indexWindowFocusRanks(into: &scratch.focusRanks)
            manager.indexWindowScratchpadSlots(into: &scratch.scratchpadSlots)
        }
        if reads.contains(.workspaceWindows) {
            output.start(
                .workspaceWindows, framed: reads.contains(.workspaceWindowFrames),
                columned: reads.contains(.workspaceWindowColumns), detailed: reads.contains(.workspaceWindowDetails)
            )
            if let id = origin.workspaceId, let workspace = manager.descriptor(for: id) {
                _ = appendScriptWindows(
                    in: workspace, session: session, resolution: resolution, to: &output, scratch: &scratch
                )
            }
            finishScriptList(&output)
        }
        if reads.contains(.windows) {
            output.start(
                .windows, framed: reads.contains(.windowFrames),
                columned: reads.contains(.windowColumns), detailed: reads.contains(.windowDetails)
            )
            for workspace in manager.sortedWorkspaces() {
                guard appendScriptWindows(
                    in: workspace, session: session, resolution: resolution, to: &output, scratch: &scratch
                ) else {
                    break
                }
            }
            finishScriptList(&output)
        }
        if reads.contains(.workspaces) {
            appendScriptWorkspaces(resolution: resolution, to: &output)
        }
        if reads.contains(.monitors) {
            output.start(.monitors, framed: reads.contains(.monitorFrames))
            appendScriptMonitors(to: &output)
            finishScriptList(&output)
        }
        appendScriptRecords(reads: reads, origin: origin, resolution: resolution, to: &output)
        #if DEBUG || OMNIWM_CONFIG_CALLBACK_TRACE
            ConfigScriptSnapshot.captures += 1
        #endif
    }

    private func appendScriptWorkspaces(
        resolution: WorkspaceManager.MonitorResolutionContext, to output: inout ConfigScriptSnapshotWriter
    ) {
        let manager = workspaceManager
        output.start(.workspaces)
        for workspace in manager.sortedWorkspaces() {
            let stored = output.row { row in
                let monitor = manager.resolvedWorkspaceMonitorId(for: workspace.id, context: resolution)
                return row.string(workspace.id.uuidString) && row.string(workspace.name)
                    && row.string(monitor?.scriptIdentifier)
            }
            if !stored { break }
        }
        finishScriptList(&output)
    }

    private func appendScriptMonitors(to output: inout ConfigScriptSnapshotWriter) {
        _ = workspaceManager.sortedMonitors().allSatisfy { monitor in
            output.row { row in
                guard row.string(monitor.id.scriptIdentifier), row.string(monitor.name) else { return false }
                if row.framed { row.frames(monitor.frame, visible: monitor.visibleFrame) }
                return true
            }
        }
    }

    private func finishScriptList(_ output: inout ConfigScriptSnapshotWriter) {
        output.finish()
        #if OMNIWM_CONFIG_CALLBACK_TRACE
            ConfigScriptSnapshot.capturedLists += 1
            ConfigScriptSnapshot.capturedRows += output.rowCount
        #endif
    }

    private func appendScriptWindows(
        in workspace: WorkspaceDescriptor, session: ConfigScriptSession,
        resolution: WorkspaceManager.MonitorResolutionContext,
        to output: inout ConfigScriptSnapshotWriter, scratch: inout ConfigScriptReadScratch
    ) -> Bool {
        let manager = workspaceManager
        let windows = manager.windowQueries
        let tokens = windows.tokens(in: workspace.id)
        guard !tokens.isEmpty else { return true }
        let shownMonitor = manager.monitorIdShowingWorkspace(workspace.id)
        let monitorId = shownMonitor ?? manager.effectiveMonitor(
            for: workspace.id, context: resolution, visibleMonitorId: shownMonitor
        )?.id
        let monitor = monitorId?.scriptIdentifier
        let layout = manager.activeLayoutKind(for: workspace.id)
        let niri = layout == .niri ? manager.niriEngine : nil
        let dwindle = layout == .dwindle ? manager.dwindleEngine?.existingState(for: workspace.id) : nil
        if output.columned { scratch.columns.index(niri, in: workspace.id, windows: tokens.count) }
        if output.acceptsDetails {
            indexScriptColumnDetails(in: workspace.id, monitorId: monitorId, engine: niri, into: &scratch.columnDetails)
        }
        for token in tokens {
            let accepted = windows.withEntry(token) { entry in
                output.row { row in
                    guard row.windowID(token, session: session), writeWindowText(entry, to: &row),
                          row.string(workspace.name), row.string(monitor) else { return false }
                    let floating = entry.mode == .floating
                    let native = entry.observedState.isNativeFullscreen
                    let fullscreen = native || (!floating && (layout == .niri
                            ? niri?.isWindowFullscreen(token, in: workspace.id) == true
                            : dwindle?.isWindowFullscreen(token) == true))
                    let flags = (floating ? OMNI_CONFIG_WINDOW_FLOATING : 0) |
                        (fullscreen ? OMNI_CONFIG_WINDOW_FULLSCREEN : 0) |
                        (native ? OMNI_CONFIG_WINDOW_NATIVE_FULLSCREEN : 0) |
                        (entry.observedState.isMinimized ? OMNI_CONFIG_WINDOW_MINIMIZED : 0)
                    guard row.flag(UInt8(flags)) else { return false }
                    if row.columned { row.column(scratch.columns.number(of: token)) }
                    if row.framed { row.frame(shownMonitor != nil ? scriptFrame(of: entry) : nil) }
                    if row.detailed {
                        row.details {
                            let indexes = ScriptWindowDetailIndexes(
                                focusRank: scratch.focusRanks[token], scratchpadSlot: scratch.scratchpadSlots[token]
                            )
                            return writeScriptWindowDetails(
                                entry, workspaceShown: shownMonitor != nil, indexes: indexes,
                                column: scratch.columnDetails[token], to: &$0
                            )
                        }
                    }
                    return true
                }
            }
            if accepted == false { return false }
        }
        return true
    }

    private func scriptFrame(of entry: borrowing WindowState) -> CGRect? {
        let manager = workspaceManager
        guard entry.hiddenState == nil, entry.layoutReason == .standard, !entry.observedState.isNativeFullscreen,
              !manager.isWindowSuppressedByMacOS(entry),
              !manager.spaceTopology.isWindowOnKnownInactiveSpace(entry.windowId)
        else { return nil }
        if entry.mode == .floating { return entry.observedState.frame }
        if case .hosted = entry.target { return nil }
        return axManager.lastAppliedFrame(for: entry.windowId)
    }

    private func appendScriptRecords(
        reads: ConfigScriptReads, origin: ScriptReadOrigin,
        resolution: @autoclosure () -> WorkspaceManager.MonitorResolutionContext,
        to output: inout ConfigScriptSnapshotWriter
    ) {
        if reads.contains(.dwindle) {
            output.start(tag: UInt8(OMNI_CONFIG_SECTION_DWINDLE))
            if let workspaceId = origin.workspaceId {
                appendScriptDwindle(in: workspaceId, session: origin.session, to: &output)
            }
            finishScriptList(&output)
        }
        if reads.contains(.placement) {
            output.start(.placement)
            appendScriptPlacement(of: origin.token, session: origin.session, resolution: resolution(), to: &output)
            finishScriptList(&output)
        }
        if reads.contains(.focusTarget) {
            output.start(.focusTarget)
            let manager = workspaceManager
            if let workspaceId = origin.workspaceId, let target = manager.resolveWorkspaceFocusToken(in: workspaceId) {
                let flags = manager.showsNativeFullscreenPlaceholder(for: target)
                    ? OMNI_CONFIG_FOCUS_TARGET_NATIVE_FULLSCREEN : 0
                _ = output.row { $0.windowID(target, session: origin.session) && $0.flag(UInt8(flags)) }
            }
            finishScriptList(&output)
        }
    }

    private func appendScriptPlacement(
        of token: WindowToken?, session: ConfigScriptSession,
        resolution: @autoclosure () -> WorkspaceManager.MonitorResolutionContext,
        to output: inout ConfigScriptSnapshotWriter
    ) {
        let manager = workspaceManager
        guard let token, let workspaceId = manager.workspace(for: token),
              let name = manager.workspaceCatalog.name(for: workspaceId)
        else { return }
        let display = manager.monitorIdShowingWorkspace(workspaceId)
            ?? manager.resolvedWorkspaceMonitorId(for: workspaceId, context: resolution())
        let engine = manager.activeLayoutKind(for: workspaceId) == .niri ? niriEngine : nil
        let strip = engine.flatMap { scriptStrip(of: token, in: workspaceId, display: display, engine: $0) }
        _ = output.row { row in
            guard row.string(name), row.string(display?.scriptIdentifier) else { return false }
            guard let strip else { return row.flag(0) }
            let flags = OMNI_CONFIG_PLACEMENT_COLUMN | (strip.vertical ? OMNI_CONFIG_PLACEMENT_VERTICAL : 0)
            guard row.flag(UInt8(flags)), row.count(strip.column), row.count(strip.columns), row.count(strip.members)
            else { return false }
            for case let window as NiriWindow in strip.node.children where strip.membership.admits(window.token) {
                guard row.windowID(window.token, session: session) else { return false }
            }
            return true
        }
    }

    private func scriptStrip(
        of token: WindowToken, in workspaceId: WorkspaceDescriptor.ID, display: Monitor.ID?, engine: NiriLayoutEngine
    ) -> ScriptStrip? {
        let manager = workspaceManager
        guard manager.withEntry(token, { $0.mode == .tiling && !manager.isWindowSuppressedByMacOS($0) }) == true,
              case let membership = engine.projectionMembership(in: workspaceId), membership.admits(token),
              let node = engine.findNode(for: token, in: workspaceId), let column = engine.column(of: node),
              let slot = engine.projectedSlot(of: column, in: workspaceId, membership: membership),
              let monitor = display.flatMap(manager.monitor(byId:))
        else { return nil }
        var members = 0
        for case let window as NiriWindow in column.children where membership.admits(window.token) {
            members += 1
        }
        guard let index = UInt16(exactly: slot.index + 1), let count = UInt16(exactly: slot.count),
              let memberCount = UInt16(exactly: members) else { return nil }
        let orientation = niriLayoutHandler.resolvedOrientation(for: workspaceId, monitor: monitor, engine: engine)
        return ScriptStrip(
            node: column, membership: membership, column: index, columns: count, members: memberCount,
            vertical: orientation == .vertical
        )
    }

    private func writeWindowText(_ entry: borrowing WindowState, to row: inout ConfigScriptSnapshotWriter) -> Bool {
        if case let .hosted(hosted) = entry.target {
            return row.string(hosted.appId) && row.string(hosted.title)
        }
        if let bundle = entry.managedReplacementMetadata?.bundleId {
            guard row.string(bundle) else { return false }
        } else if !appInfoCache.withCachedBundleId(for: entry.pid, { row.string($0) }) {
            return false
        }
        if let title = entry.managedReplacementMetadata?.title { return row.string(title) }
        guard let id = UInt32(exactly: entry.token.windowId) else { return row.string(nil) }
        return AXWindowService.withCachedTitle(windowId: id) { row.string($0) }
    }
}
