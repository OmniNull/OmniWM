// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMScriptHost

struct ConfigScriptReads: OptionSet, Sendable {
    let rawValue: UInt16
    static let workspaceWindows = Self(rawValue: UInt16(OMNI_CONFIG_READ_WORKSPACE_WINDOWS))
    static let windows = Self(rawValue: UInt16(OMNI_CONFIG_READ_WINDOWS))
    static let workspaces = Self(rawValue: UInt16(OMNI_CONFIG_READ_WORKSPACES))
    static let monitors = Self(rawValue: UInt16(OMNI_CONFIG_READ_MONITORS))
    static let placement = Self(rawValue: UInt16(OMNI_CONFIG_READ_PLACEMENT))
    static let focusTarget = Self(rawValue: UInt16(OMNI_CONFIG_READ_FOCUS_TARGET))
    static let workspaceWindowFrames = Self(rawValue: UInt16(OMNI_CONFIG_READ_WORKSPACE_WINDOW_FRAMES))
    static let windowFrames = Self(rawValue: UInt16(OMNI_CONFIG_READ_WINDOW_FRAMES))
    static let monitorFrames = Self(rawValue: UInt16(OMNI_CONFIG_READ_MONITOR_FRAMES))
    static let workspaceWindowColumns = Self(rawValue: UInt16(OMNI_CONFIG_READ_WORKSPACE_WINDOW_COLUMNS))
    static let windowColumns = Self(rawValue: UInt16(OMNI_CONFIG_READ_WINDOW_COLUMNS))
    static let lists = Self(rawValue: UInt16(OMNI_CONFIG_READ_LISTS))

    var frameByteLimit: Int {
        let windowSections = intersection([.workspaceWindowFrames, .windowFrames]).rawValue.nonzeroBitCount
        let monitorSections = contains(.monitorFrames) ? 1 : 0
        return ConfigScriptSnapshot.rowLimit * (windowSections * ConfigScriptSnapshot.windowFrameBytes
            + monitorSections * ConfigScriptSnapshot.monitorFrameBytes)
    }

    var columnByteLimit: Int {
        let sections = intersection([.workspaceWindowColumns, .windowColumns]).rawValue.nonzeroBitCount
        return ConfigScriptSnapshot.rowLimit * sections * ConfigScriptSnapshot.columnBytes
    }
}

struct ConfigScriptSnapshot: Sendable {
    static let rowLimit = 256
    static let byteLimit = 128 * 1024
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
    private var capacityHints: [UInt16: Int] = [:]
    private var columns = ConfigScriptColumnIndex()

    fileprivate mutating func capture(
        reads: ConfigScriptReads, write: (inout SnapshotWriter, inout ConfigScriptColumnIndex) -> Void
    ) -> ConfigScriptSnapshot {
        var index = slots.startIndex
        while index < slots.endIndex, !isKnownUniquelyReferenced(&slots[index].reservation) {
            index += 1
        }
        if index == slots.endIndex { slots.append(Slot()) }
        let lists = reads.intersection(.lists).rawValue.nonzeroBitCount
        let limit = lists * ConfigScriptSnapshot.byteLimit + reads.frameByteLimit + reads.columnByteLimit
        var output = SnapshotWriter(limit: limit)
        swap(&slots[index].storage, &output.bytes)
        output.bytes.removeAll(keepingCapacity: true)
        let capacity = capacityHints[reads.rawValue] ?? 0
        output.bytes.reserveCapacity(capacity == 0 ? limit : capacity)
        write(&output, &columns)
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

private struct SnapshotWriter {
    let limit: Int
    var bytes: [UInt8] = []
    private var header = 0
    private var rows: UInt16 = 0
    private var truncated = false
    private(set) var framed = false
    private(set) var columned = false
    private var frameBytes = 0
    private var columnBytes = 0

    init(limit: Int) {
        self.limit = limit
    }

    private mutating func makeRoom(for payload: Int, prefix: Int = 0) -> Bool {
        guard payload <= remaining - prefix else { return false }
        reserve(payload + prefix)
        return true
    }

    private mutating func reserve(_ count: Int) {
        if count > bytes.capacity - bytes.count { bytes.reserveCapacity(limit) }
    }

    private var remaining: Int {
        ConfigScriptSnapshot.byteLimit - (bytes.count - header - frameBytes - columnBytes)
    }

    mutating func start(_ kind: ConfigScriptReads, framed: Bool = false, columned: Bool = false) {
        header = bytes.count
        rows = 0
        truncated = false
        self.framed = framed
        self.columned = columned
        frameBytes = 0
        columnBytes = 0
        reserve(MemoryLayout<UInt64>.size)
        appendLE(UInt64(kind.rawValue))
    }

    mutating func finish() {
        let length = UInt32(bytes.count - header - MemoryLayout<UInt64>.size)
        let section = (truncated ? OMNI_CONFIG_SECTION_TRUNCATED : 0) | (framed ? OMNI_CONFIG_SECTION_FRAMES : 0)
            | (columned ? OMNI_CONFIG_SECTION_COLUMNS : 0)
        let flags = UInt64(bytes[header]) | (UInt64(section) << 8)
        let value = flags | (UInt64(rows) << 16) | (UInt64(length) << 32)
        bytes.withUnsafeMutableBytes { $0.storeBytes(of: value.littleEndian, toByteOffset: header, as: UInt64.self) }
    }

    mutating func row(_ write: (inout Self) -> Bool) -> Bool {
        guard rows < ConfigScriptSnapshot.rowLimit else {
            truncated = true
            return false
        }
        let start = bytes.count
        let frames = frameBytes
        let columns = columnBytes
        guard write(&self) else {
            bytes.removeSubrange(start...)
            frameBytes = frames
            columnBytes = columns
            truncated = true
            return false
        }
        rows += 1
        return true
    }

    mutating func column(_ number: UInt16) {
        reserve(ConfigScriptSnapshot.columnBytes)
        appendLE(number)
        columnBytes += ConfigScriptSnapshot.columnBytes
    }

    mutating func frame(_ frame: CGRect?) {
        reserve(ConfigScriptSnapshot.windowFrameBytes)
        bytes.append(frame == nil ? 0 : UInt8(OMNI_CONFIG_FRAME_PRESENT))
        frameBytes += MemoryLayout<UInt8>.size
        if let frame { appendRect(frame) }
    }

    mutating func frames(_ frame: CGRect, visible: CGRect) {
        reserve(ConfigScriptSnapshot.monitorFrameBytes)
        appendRect(frame)
        appendRect(visible)
    }

    private mutating func appendRect(_ rect: CGRect) {
        appendLE(Double(rect.origin.x).bitPattern)
        appendLE(Double(rect.origin.y).bitPattern)
        appendLE(Double(rect.size.width).bitPattern)
        appendLE(Double(rect.size.height).bitPattern)
        frameBytes += MemoryLayout<CGRect>.size
    }

    mutating func string(_ value: borrowing String?) -> Bool {
        if value != nil { return string(value!) }
        guard makeRoom(for: MemoryLayout<UInt32>.size) else { return false }
        appendLE(UInt32.max)
        return true
    }

    mutating func string(_ value: borrowing String) -> Bool {
        let prefix = MemoryLayout<UInt32>.size
        if let stored = value.utf8.withContiguousStorageIfAvailable({ source in
            guard makeRoom(for: source.count, prefix: prefix) else { return false }
            appendLE(UInt32(source.count))
            bytes.append(contentsOf: source)
            return true
        }) { return stored }
        guard makeRoom(for: prefix) else { return false }
        let offset = bytes.count
        appendLE(UInt32.zero)
        for byte in value.utf8 {
            guard flag(byte) else { return false }
        }
        let length = UInt32(bytes.count - offset - prefix)
        bytes.withUnsafeMutableBytes { $0.storeBytes(of: length.littleEndian, toByteOffset: offset, as: UInt32.self) }
        return true
    }

    mutating func windowID(_ token: WindowToken, session: ConfigScriptSession) -> Bool {
        ConfigScriptWindowID.withBytes(token, session: session) { id in
            guard makeRoom(for: id.count, prefix: MemoryLayout<UInt32>.size) else { return false }
            appendLE(UInt32(id.count))
            bytes.append(contentsOf: id)
            return true
        }
    }

    mutating func flag(_ value: UInt8) -> Bool {
        guard makeRoom(for: MemoryLayout<UInt8>.size) else { return false }
        bytes.append(value)
        return true
    }

    mutating func count(_ value: UInt16) -> Bool {
        guard makeRoom(for: MemoryLayout<UInt16>.size) else { return false }
        appendLE(value)
        return true
    }

    private mutating func appendLE(_ value: some FixedWidthInteger) {
        withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
    }

    #if OMNIWM_CONFIG_CALLBACK_TRACE
        var rowCount: Int {
            Int(rows)
        }
    #endif
}

extension WMController {
    func configScriptSnapshot(
        reads: ConfigScriptReads, target: borrowing ConfigScriptTarget, pool: inout ConfigScriptSnapshotPool
    ) -> ConfigScriptSnapshot {
        let origin = ScriptReadOrigin(workspaceId: target.workspaceId, token: target.token, session: target.sessionID)
        return pool.capture(reads: reads) { writeSnapshot(reads: reads, origin: origin, to: &$0, columns: &$1) }
    }

    private func writeSnapshot(
        reads: ConfigScriptReads, origin: ScriptReadOrigin, to output: inout SnapshotWriter,
        columns: inout ConfigScriptColumnIndex
    ) {
        let manager = workspaceManager
        let session = origin.session
        lazy var resolution = manager.monitorResolutionContext()
        if reads.contains(.workspaceWindows) {
            output.start(
                .workspaceWindows, framed: reads.contains(.workspaceWindowFrames),
                columned: reads.contains(.workspaceWindowColumns)
            )
            if let id = origin.workspaceId, let workspace = manager.descriptor(for: id) {
                _ = appendScriptWindows(
                    in: workspace, session: session, resolution: resolution, to: &output, columns: &columns
                )
            }
            finishScriptList(&output)
        }
        if reads.contains(.windows) {
            output.start(.windows, framed: reads.contains(.windowFrames), columned: reads.contains(.windowColumns))
            for workspace in manager.sortedWorkspaces() {
                guard appendScriptWindows(
                    in: workspace, session: session, resolution: resolution, to: &output, columns: &columns
                ) else {
                    break
                }
            }
            finishScriptList(&output)
        }
        if reads.contains(.workspaces) {
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

    private func appendScriptMonitors(to output: inout SnapshotWriter) {
        _ = workspaceManager.sortedMonitors().allSatisfy { monitor in
            output.row { row in
                guard row.string(monitor.id.scriptIdentifier), row.string(monitor.name) else { return false }
                if row.framed { row.frames(monitor.frame, visible: monitor.visibleFrame) }
                return true
            }
        }
    }

    private func finishScriptList(_ output: inout SnapshotWriter) {
        output.finish()
        #if OMNIWM_CONFIG_CALLBACK_TRACE
            ConfigScriptSnapshot.capturedLists += 1
            ConfigScriptSnapshot.capturedRows += output.rowCount
        #endif
    }

    private func appendScriptWindows(
        in workspace: WorkspaceDescriptor, session: ConfigScriptSession,
        resolution: WorkspaceManager.MonitorResolutionContext,
        to output: inout SnapshotWriter, columns: inout ConfigScriptColumnIndex
    ) -> Bool {
        let manager = workspaceManager
        let windows = manager.windowQueries
        let tokens = windows.tokens(in: workspace.id)
        guard !tokens.isEmpty else { return true }
        let shownMonitor = manager.monitorIdShowingWorkspace(workspace.id)
        let monitor = (shownMonitor ?? manager.effectiveMonitor(
            for: workspace.id, context: resolution, visibleMonitorId: shownMonitor
        )?.id)?.scriptIdentifier
        let layout = manager.activeLayoutKind(for: workspace.id)
        let niri = layout == .niri ? manager.niriEngine : nil
        let dwindle = layout == .dwindle ? manager.dwindleEngine?.existingState(for: workspace.id) : nil
        let shown = output.framed && shownMonitor != nil
        if output.columned { columns.index(niri, in: workspace.id, windows: tokens.count) }
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
                    if row.columned { row.column(columns.number(of: token)) }
                    if row.framed { row.frame(shown ? scriptFrame(of: entry) : nil) }
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
        to output: inout SnapshotWriter
    ) {
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
        to output: inout SnapshotWriter
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

    private func writeWindowText(_ entry: borrowing WindowState, to row: inout SnapshotWriter) -> Bool {
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
