// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension IPCSizeChange {
    public init?(token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let isProportion = trimmed.hasSuffix("%")
        let numericText = isProportion ? String(trimmed.dropLast()) : trimmed
        guard let value = Double(numericText), value.isFinite else { return nil }
        if trimmed.hasPrefix("+") || trimmed.hasPrefix("-") {
            self = isProportion ? .adjustProportion(value) : .adjustFixed(value)
        } else {
            self = isProportion ? .setProportion(value) : .setFixed(value)
        }
    }
}

extension IPCCommandArgumentValue {
    public init?(token: String, kind: IPCCommandArgumentKind) {
        switch kind {
        case .appID:
            guard !token.isEmpty else { return nil }
            self = .appID(token)
        case .direction:
            guard let direction = IPCDirection(rawValue: token) else { return nil }
            self = .direction(direction)
        case .workspaceNumber,
             .columnIndex,
             .windowIndex:
            guard let value = Int(token), value > 0 else { return nil }
            self = .integer(value)
        case .scratchpadIndex,
             .visibleContainerCount:
            let range = kind == .scratchpadIndex ? IPCScratchpadSlots.range : IPCVisibleContainerCounts.range
            guard let value = Int(token), range.contains(value) else { return nil }
            self = .integer(value)
        case .layout:
            guard let layout = IPCWorkspaceLayout(rawValue: token) else { return nil }
            self = .layout(layout)
        case .paletteMode:
            guard let mode = IPCCommandPaletteMode(rawValue: token) else { return nil }
            self = .paletteMode(mode)
        case .switcherDirection,
             .switcherScope:
            guard let value = Self.windowSwitcherValue(token: token, kind: kind) else { return nil }
            self = value
        case .resizeAxis:
            guard let axis = IPCResizeAxis(rawValue: token) else { return nil }
            self = .resizeAxis(axis)
        case .resizeOperation:
            guard let operation = IPCResizeOperation(rawValue: token) else { return nil }
            self = .resizeOperation(operation)
        case .sizeChange:
            guard let change = IPCSizeChange(token: token) else { return nil }
            self = .sizeChange(change)
        }
    }

    private static func windowSwitcherValue(token: String, kind: IPCCommandArgumentKind) -> Self? {
        kind == .switcherScope
            ? IPCWindowSwitcherScope(rawValue: token).map(Self.switcherScope)
            : IPCWindowSwitcherDirection(rawValue: token).map(Self.switcherDirection)
    }
}
