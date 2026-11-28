// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMAutomation

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
