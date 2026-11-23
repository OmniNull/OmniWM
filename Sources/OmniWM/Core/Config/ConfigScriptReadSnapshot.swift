// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMIPC
import OmniWMScriptHost

struct ConfigScriptReads: OptionSet, Sendable {
    let rawValue: UInt8
    static let workspaceWindows = Self(rawValue: UInt8(OMNI_CONFIG_READ_WORKSPACE_WINDOWS))
    static let windows = Self(rawValue: UInt8(OMNI_CONFIG_READ_WINDOWS))
    static let workspaces = Self(rawValue: UInt8(OMNI_CONFIG_READ_WORKSPACES))
    static let monitors = Self(rawValue: UInt8(OMNI_CONFIG_READ_MONITORS))
}

struct ConfigScriptSnapshot: Sendable {
    static let rowLimit = 256
    static let byteLimit = 128 * 1024
    let bytes: Data

    #if DEBUG || OMNIWM_CONFIG_CALLBACK_TRACE
        @MainActor static var captures = 0
    #endif

    #if OMNIWM_CONFIG_CALLBACK_TRACE
        @MainActor static var capturedLists = 0
        @MainActor static var capturedRows = 0
    #endif
}

private struct SnapshotWriter {
    var bytes = Data()
    private var header = 0
    private var rows: UInt16 = 0
    private var truncated = false

    mutating func start(_ kind: ConfigScriptReads) {
        header = bytes.count
        rows = 0
        truncated = false
        appendLE(UInt64(kind.rawValue))
    }

    mutating func finish() {
        let length = UInt32(bytes.count - header - MemoryLayout<UInt64>.size)
        let flags = UInt64(bytes[header]) | (truncated ? 1 << 8 : 0)
        let value = flags | (UInt64(rows) << 16) | (UInt64(length) << 32)
        bytes.withUnsafeMutableBytes { $0.storeBytes(of: value.littleEndian, toByteOffset: header, as: UInt64.self) }
    }

    mutating func row(_ write: (inout Self) -> Bool) -> Bool {
        guard rows < ConfigScriptSnapshot.rowLimit else {
            truncated = true
            return false
        }
        let start = bytes.count
        guard write(&self), bytes.count - header <= ConfigScriptSnapshot.byteLimit else {
            bytes.removeSubrange(start...)
            truncated = true
            return false
        }
        rows += 1
        return true
    }

    mutating func string(_ value: String?) -> Bool {
        let available = ConfigScriptSnapshot.byteLimit - (bytes.count - header) - MemoryLayout<UInt32>.size
        guard available >= 0 else { return false }
        guard var value else {
            appendLE(UInt32.max)
            return true
        }
        let count = value.utf8.count
        guard count <= available else { return false }
        appendLE(UInt32(count))
        value.withUTF8 { bytes.append($0) }
        return true
    }

    mutating func windowID(_ token: WindowToken, using encoder: borrowing IPCWindowOpaqueID.Encoder) -> Bool {
        let offset = bytes.count
        appendLE(UInt32(0))
        encoder.append(pid: token.pid, windowId: token.windowId, to: &bytes)
        guard bytes.count - header <= ConfigScriptSnapshot.byteLimit else { return false }
        let length = UInt32(bytes.count - offset - MemoryLayout<UInt32>.size)
        bytes.withUnsafeMutableBytes { $0.storeBytes(of: length.littleEndian, toByteOffset: offset, as: UInt32.self) }
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
        reads: ConfigScriptReads, target: borrowing ConfigScriptTarget
    ) -> ConfigScriptSnapshot {
        let manager = workspaceManager
        var output = SnapshotWriter()
        lazy var resolution = manager.monitorResolutionContext()
        let session = target.session
        lazy var ids = IPCWindowOpaqueID.Encoder(sessionToken: session)
        if reads.contains(.workspaceWindows) {
            output.start(.workspaceWindows)
            if let id = target.workspaceId, let workspace = manager.descriptor(for: id) {
                _ = appendScriptWindows(in: workspace, ids: ids, resolution: resolution, to: &output)
            }
            finishScriptList(&output)
        }
        if reads.contains(.windows) {
            output.start(.windows)
            for workspace in manager.sortedWorkspaces() {
                guard appendScriptWindows(in: workspace, ids: ids, resolution: resolution, to: &output)
                else {
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
                        && row.string(monitor.map(IPCDisplayRef.identifier))
                }
                if !stored { break }
            }
            finishScriptList(&output)
        }
        if reads.contains(.monitors) {
            output.start(.monitors)
            _ = manager.sortedMonitors().allSatisfy { monitor in
                output.row { $0.string(IPCDisplayRef.identifier(monitor.id)) && $0.string(monitor.name) }
            }
            finishScriptList(&output)
        }
        #if DEBUG || OMNIWM_CONFIG_CALLBACK_TRACE
            ConfigScriptSnapshot.captures += 1
        #endif
        return ConfigScriptSnapshot(bytes: output.bytes)
    }

    private func finishScriptList(_ output: inout SnapshotWriter) {
        output.finish()
        #if OMNIWM_CONFIG_CALLBACK_TRACE
            ConfigScriptSnapshot.capturedLists += 1
            ConfigScriptSnapshot.capturedRows += output.rowCount
        #endif
    }

    private func appendScriptWindows(
        in workspace: WorkspaceDescriptor, ids: IPCWindowOpaqueID.Encoder,
        resolution: WorkspaceManager.MonitorResolutionContext,
        to output: inout SnapshotWriter
    ) -> Bool {
        let manager = workspaceManager
        let windows = manager.windowQueries
        let tokens = windows.tokens(in: workspace.id)
        guard !tokens.isEmpty else { return true }
        let monitor = manager.resolvedWorkspaceMonitorId(for: workspace.id, context: resolution)
            .map(IPCDisplayRef.identifier)
        let layout = manager.activeLayoutKind(for: workspace.id)
        for token in tokens {
            let accepted = windows.withEntry(token) { entry in
                output.row { row in
                    let hosted = entry.target.hostedMetadata
                    let bundle = hosted?.appId ?? entry.managedReplacementMetadata?.bundleId
                        ?? appInfoCache.cachedBundleId(for: entry.pid)
                    let title = hosted?.title ?? entry.managedReplacementMetadata?.title
                        ?? UInt32(exactly: token.windowId).flatMap(AXWindowService.cachedTitle(windowId:))
                    guard row.windowID(token, using: ids), row.string(bundle),
                          row.string(title),
                          row.string(workspace.name), row.string(monitor) else { return false }
                    let floating = entry.mode == .floating
                    let fullscreen = entry.observedState.isNativeFullscreen || (!floating && (layout == .niri
                            ? manager.niriEngine?.isWindowFullscreen(token, in: workspace.id) == true
                            : manager.dwindleEngine?.isWindowFullscreen(token, in: workspace.id) == true))
                    let flags: UInt8 = (floating ? 1 : 0) | (fullscreen ? 2 : 0) |
                        (entry.observedState.isMinimized ? 4 : 0)
                    row.bytes.append(flags)
                    return true
                }
            }
            if accepted == false { return false }
        }
        return true
    }
}
