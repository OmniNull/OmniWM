// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import OmniWMIPC
import OmniWMScriptHost

struct ConfigScriptWindowRequest: Equatable, Sendable {
    let name: IPCWindowActionName
    let action: WindowAction
    let session: ConfigScriptSession
    let token: WindowToken

    init(name: IPCWindowActionName, action: WindowAction, session: ConfigScriptSession, token: WindowToken) {
        self.name = name
        self.action = action
        self.session = session
        self.token = token
    }

    init(words: UnsafeBufferPointer<omni_config_span>) throws(ConfigScriptError) {
        guard (2 ... 3).contains(words.count), let name = Self.actionName(Self.bytes(words[0])) else {
            throw Self.invalid
        }
        let action: WindowAction?
        if words.count == 3 {
            guard let argument = String(validating: Self.bytes(words[2]), as: UTF8.self) else {
                throw ConfigScriptError(line: nil, message: "Command words and chords must be valid UTF-8.")
            }
            action = Self.action(name, argument: argument)
        } else {
            action = Self.action(name)
        }
        guard let action else { throw Self.invalid }
        guard let id = ConfigScriptWindowID.decode(Self.bytes(words[1])) else {
            throw ConfigScriptError(line: nil, message: "Expected a session-scoped window ID.")
        }
        self.init(name: name, action: action, session: id.session, token: id.token)
    }

    private static let invalid = ConfigScriptError(line: nil, message: "Invalid window action or arguments.")
    private static let actionNames = IPCWindowActionName.allCases

    private static func bytes(_ span: omni_config_span) -> UnsafeRawBufferPointer {
        UnsafeRawBufferPointer(start: span.data, count: span.length)
    }

    private static func actionName(_ bytes: UnsafeRawBufferPointer) -> IPCWindowActionName? {
        actionNames.first { $0.rawValue.utf8.count == bytes.count && $0.rawValue.utf8.elementsEqual(bytes) }
    }

    private static func action(_ name: IPCWindowActionName) -> WindowAction? {
        switch name {
        case .focus: .focus
        case .navigate: .navigate
        case .summonRight: .summonRight
        case .close: .close
        case .moveColumnToFirst: .moveColumn(.first)
        case .moveColumnToLast: .moveColumn(.last)
        case .toggleContainerFullPrimarySpan: .toggleContainerFullPrimarySpan
        case .resetWindowSecondarySpan: .resetWindowSecondarySpan
        case .toggleColumnTabbed: .toggleColumnTabbed
        case .toggleFloating: .toggleFloating
        default: nil
        }
    }

    private static func action(_ name: IPCWindowActionName, argument: String) -> WindowAction? {
        switch name {
        case .moveToWorkspace:
            .moveToWorkspace(WorkspaceTarget(resolvingInput: argument))
        case .moveColumnToIndex:
            Int(argument).flatMap { $0 > 0 ? .moveColumn(.index($0)) : nil }
        case .moveColumn:
            Direction(rawValue: argument).map { .moveColumn(.direction($0)) }
        case .setContainerPrimarySpan:
            IPCSizeChange(token: argument).map { .setContainerPrimarySpan(NiriSizeChange(ipc: $0)) }
        case .setWindowPrimarySpan:
            IPCSizeChange(token: argument).map { .setWindowPrimarySpan(NiriSizeChange(ipc: $0)) }
        case .setWindowSecondarySpan:
            IPCSizeChange(token: argument).map { .setWindowSecondarySpan(NiriSizeChange(ipc: $0)) }
        case .cycleWindowPrimarySpan:
            IPCCycleDirection(rawValue: argument).map { .cycleWindowPrimarySpan(forward: $0 == .forward) }
        case .cycleWindowSecondarySpan:
            IPCCycleDirection(rawValue: argument).map { .cycleWindowSecondarySpan(forward: $0 == .forward) }
        case .assignToScratchpad:
            Int(argument).flatMap { IPCScratchpadSlots.range.contains($0) ? ScratchpadIndex($0) : nil }
                .map { .assignToScratchpad($0) }
        default:
            nil
        }
    }
}
