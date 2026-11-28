// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import OmniWMScriptHost

struct ConfigScriptReads: OptionSet, Sendable {
    let rawValue: UInt32
    static let workspaceWindows = Self(rawValue: UInt32(OMNI_CONFIG_READ_WORKSPACE_WINDOWS))
    static let windows = Self(rawValue: UInt32(OMNI_CONFIG_READ_WINDOWS))
    static let workspaces = Self(rawValue: UInt32(OMNI_CONFIG_READ_WORKSPACES))
    static let monitors = Self(rawValue: UInt32(OMNI_CONFIG_READ_MONITORS))
    static let placement = Self(rawValue: UInt32(OMNI_CONFIG_READ_PLACEMENT))
    static let focusTarget = Self(rawValue: UInt32(OMNI_CONFIG_READ_FOCUS_TARGET))
    static let workspaceWindowFrames = Self(rawValue: UInt32(OMNI_CONFIG_READ_WORKSPACE_WINDOW_FRAMES))
    static let windowFrames = Self(rawValue: UInt32(OMNI_CONFIG_READ_WINDOW_FRAMES))
    static let monitorFrames = Self(rawValue: UInt32(OMNI_CONFIG_READ_MONITOR_FRAMES))
    static let workspaceWindowColumns = Self(rawValue: UInt32(OMNI_CONFIG_READ_WORKSPACE_WINDOW_COLUMNS))
    static let windowColumns = Self(rawValue: UInt32(OMNI_CONFIG_READ_WINDOW_COLUMNS))
    static let workspaceWindowDetails = Self(rawValue: UInt32(OMNI_CONFIG_READ_WORKSPACE_WINDOW_DETAILS))
    static let windowDetails = Self(rawValue: UInt32(OMNI_CONFIG_READ_WINDOW_DETAILS))
    static let workspaceDetails = Self(rawValue: UInt32(OMNI_CONFIG_READ_WORKSPACE_DETAILS))
    static let monitorDetails = Self(rawValue: UInt32(OMNI_CONFIG_READ_MONITOR_DETAILS))
    static let windowDetailSections: Self = [.workspaceWindowDetails, .windowDetails]
    static let detailSections: Self = windowDetailSections.union([.workspaceDetails, .monitorDetails])
    static let lists = Self(rawValue: UInt32(OMNI_CONFIG_READ_LISTS))
    static let dwindle = Self(rawValue: UInt32(OMNI_CONFIG_READ_DWINDLE))
    static let marks = Self(rawValue: UInt32(OMNI_CONFIG_READ_MARKS))
    static let apps = Self(rawValue: UInt32(OMNI_CONFIG_READ_APPS))
    static let rules = Self(rawValue: UInt32(OMNI_CONFIG_READ_RULES))
    static let workspaceBar = Self(rawValue: UInt32(OMNI_CONFIG_READ_WORKSPACE_BAR))
    static let shell = Self(rawValue: UInt32(OMNI_CONFIG_READ_SHELL))
    static let sections = lists.union([dwindle, marks, apps, rules, workspaceBar, shell])

    var frameByteLimit: Int {
        let windowSections = intersection([.workspaceWindowFrames, .windowFrames]).rawValue.nonzeroBitCount
        let monitorSections = contains(.monitorFrames) ? 1 : 0
        return ConfigScriptSnapshot.rowLimit * (windowSections * ConfigScriptSnapshot.windowFrameBytes
            + monitorSections * ConfigScriptSnapshot.monitorFrameBytes)
    }

    var detailByteLimit: Int {
        intersection(.detailSections).rawValue.nonzeroBitCount * ConfigScriptSnapshot.detailByteLimit
    }

    var columnByteLimit: Int {
        let sections = intersection([.workspaceWindowColumns, .windowColumns]).rawValue.nonzeroBitCount
        return ConfigScriptSnapshot.rowLimit * sections * ConfigScriptSnapshot.columnBytes
    }
}
