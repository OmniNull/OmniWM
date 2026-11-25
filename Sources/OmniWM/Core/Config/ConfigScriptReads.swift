// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

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
    static let dwindle = Self(rawValue: UInt16(OMNI_CONFIG_READ_DWINDLE))
    static let sections = lists.union(dwindle)

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
