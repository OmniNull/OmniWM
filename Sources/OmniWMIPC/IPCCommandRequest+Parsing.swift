// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

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
        case .direction:
            guard let direction = IPCDirection(rawValue: token) else { return nil }
            self = .direction(direction)
        case .workspaceNumber,
             .columnIndex,
             .windowIndex:
            guard let value = Int(token), value > 0 else { return nil }
            self = .integer(value)
        case .scratchpadIndex:
            guard let value = Int(token), IPCScratchpadSlots.range.contains(value) else { return nil }
            self = .integer(value)
        case .layout:
            guard let layout = IPCWorkspaceLayout(rawValue: token) else { return nil }
            self = .layout(layout)
        case .paletteMode:
            guard let mode = IPCCommandPaletteMode(rawValue: token) else { return nil }
            self = .paletteMode(mode)
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
}

extension IPCCommandRequest {
    public init?(commandWords words: [String]) {
        for descriptor in IPCAutomationManifest.commandDescriptors(matching: words) {
            let wordCount = descriptor.commandWords.count
            guard words.count - wordCount == descriptor.arguments.count else { continue }
            let values = zip(descriptor.arguments, words.dropFirst(wordCount)).compactMap {
                IPCCommandArgumentValue(token: $1, kind: $0.kind)
            }
            guard values.count == descriptor.arguments.count,
                  let request = try? IPCCommandRequest(name: descriptor.name, argumentValues: values)
            else {
                continue
            }
            self = request
            return
        }
        return nil
    }
}

extension IPCWindowRequest {
    public init?(actionWords words: [String]) {
        guard let action = words.first.flatMap(IPCWindowActionName.init(rawValue:)),
              let descriptor = IPCAutomationManifest.windowActionDescriptors.first(where: { $0.name == action }),
              words.count == 1 + descriptor.arguments.count
        else {
            return nil
        }
        guard let argument = words.dropFirst(2).first else {
            self.init(name: action, windowId: words[1])
            return
        }
        switch action {
        case .moveToWorkspace:
            self.init(name: action, windowId: words[1], workspaceTarget: WorkspaceTarget(resolvingInput: argument))
        case .moveColumnToIndex:
            guard let index = Int(argument), index > 0 else { return nil }
            self.init(name: action, windowId: words[1], columnIndex: index)
        case .moveColumn:
            guard let direction = IPCDirection(rawValue: argument) else { return nil }
            self.init(name: action, windowId: words[1], direction: direction)
        case .setContainerPrimarySpan,
             .setWindowPrimarySpan,
             .setWindowSecondarySpan:
            guard let change = IPCSizeChange(token: argument) else { return nil }
            self.init(name: action, windowId: words[1], change: change)
        case .cycleWindowPrimarySpan,
             .cycleWindowSecondarySpan:
            guard let cycle = IPCCycleDirection(rawValue: argument) else { return nil }
            self.init(name: action, windowId: words[1], cycle: cycle)
        case .assignToScratchpad:
            guard let index = Int(argument), IPCScratchpadSlots.range.contains(index) else { return nil }
            self.init(name: action, windowId: words[1], scratchpadIndex: index)
        case .focus,
             .navigate,
             .summonRight,
             .close,
             .moveColumnToFirst,
             .moveColumnToLast,
             .toggleContainerFullPrimarySpan,
             .resetWindowSecondarySpan,
             .toggleColumnTabbed,
             .toggleFloating:
            return nil
        }
    }
}
