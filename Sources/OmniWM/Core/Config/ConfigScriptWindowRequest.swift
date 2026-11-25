// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import OmniWMIPC
import OmniWMScriptHost

enum ConfigScriptWindowActionName: Equatable, Sendable {
    case shared(IPCWindowActionName)
    case placeInOwnColumn

    static let allCases = IPCWindowActionName.allCases.map(Self.shared) + [.placeInOwnColumn]

    var rawValue: String {
        switch self {
        case let .shared(name): name.rawValue
        case .placeInOwnColumn: "place-in-own-column"
        }
    }
}

struct ConfigScriptWindowRequest: Equatable, Sendable {
    let name: ConfigScriptWindowActionName
    let action: WindowAction
    let session: ConfigScriptSession
    let token: WindowToken
    let check: ConfigScriptWindowCheck?

    init(
        name: ConfigScriptWindowActionName,
        action: WindowAction,
        session: ConfigScriptSession,
        token: WindowToken,
        check: ConfigScriptWindowCheck? = nil
    ) {
        self.name = name
        self.action = action
        self.session = session
        self.token = token
        self.check = check
    }

    init(
        words: UnsafeBufferPointer<omni_config_span>,
        destination: UnsafeBufferPointer<omni_config_field>? = nil
    ) throws(ConfigScriptError) {
        guard (2 ... 3).contains(words.count), let name = Self.actionName(Self.bytes(words[0])) else {
            throw Self.invalid
        }
        var check: ConfigScriptWindowCheck?
        let action: WindowAction?
        if let destination {
            switch (name, words.count) {
            case (.shared(.moveToWorkspace), 2):
                let parsed = try ConfigScriptWindowDestination(fields: destination)
                action = .moveToDisplay(parsed.target, column: parsed.column)
                check = parsed.fromEdge ? .fromEdge : nil
            case (.shared(.focus), 2):
                action = .focus
                check = try .focus(fields: destination)
            default:
                throw ConfigScriptError(line: nil, message: "Only move-to-workspace and focus take a table.")
            }
        } else if words.count == 3 {
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
        self.init(name: name, action: action, session: id.session, token: id.token, check: check)
    }

    private static let invalid = ConfigScriptError(line: nil, message: "Invalid window action or arguments.")
    private static let actionNames = ConfigScriptWindowActionName.allCases

    private static func bytes(_ span: omni_config_span) -> UnsafeRawBufferPointer {
        UnsafeRawBufferPointer(start: span.data, count: span.length)
    }

    private static func actionName(_ bytes: UnsafeRawBufferPointer) -> ConfigScriptWindowActionName? {
        actionNames.first { $0.rawValue.utf8.count == bytes.count && $0.rawValue.utf8.elementsEqual(bytes) }
    }

    private static func action(_ name: ConfigScriptWindowActionName) -> WindowAction? {
        switch name {
        case .shared(.focus): .focus
        case .shared(.navigate): .navigate
        case .shared(.summonRight): .summonRight
        case .shared(.close): .close
        case .shared(.moveColumnToFirst): .moveColumn(.first)
        case .shared(.moveColumnToLast): .moveColumn(.last)
        case .shared(.toggleContainerFullPrimarySpan): .toggleContainerFullPrimarySpan
        case .shared(.resetWindowSecondarySpan): .resetWindowSecondarySpan
        case .shared(.toggleColumnTabbed): .toggleColumnTabbed
        case .shared(.toggleFloating): .toggleFloating
        default: nil
        }
    }

    private static func action(_ name: ConfigScriptWindowActionName, argument: String) -> WindowAction? {
        switch name {
        case .shared(.moveToWorkspace):
            .moveToWorkspace(WorkspaceTarget(resolvingInput: argument))
        case .shared(.moveColumnToIndex):
            Int(argument).flatMap { $0 > 0 ? .moveColumn(.index($0)) : nil }
        case .placeInOwnColumn:
            Int(argument).flatMap { $0 > 0 ? .placeInOwnColumn($0) : nil }
        case .shared(.moveColumn):
            Direction(rawValue: argument).map { .moveColumn(.direction($0)) }
        case .shared(.setContainerPrimarySpan):
            IPCSizeChange(token: argument).map { .setContainerPrimarySpan(NiriSizeChange(ipc: $0)) }
        case .shared(.setWindowPrimarySpan):
            IPCSizeChange(token: argument).map { .setWindowPrimarySpan(NiriSizeChange(ipc: $0)) }
        case .shared(.setWindowSecondarySpan):
            IPCSizeChange(token: argument).map { .setWindowSecondarySpan(NiriSizeChange(ipc: $0)) }
        case .shared(.cycleWindowPrimarySpan):
            IPCCycleDirection(rawValue: argument).map { .cycleWindowPrimarySpan(forward: $0 == .forward) }
        case .shared(.cycleWindowSecondarySpan):
            IPCCycleDirection(rawValue: argument).map { .cycleWindowSecondarySpan(forward: $0 == .forward) }
        case .shared(.assignToScratchpad):
            Int(argument).flatMap { IPCScratchpadSlots.range.contains($0) ? ScratchpadIndex($0) : nil }
                .map { .assignToScratchpad($0) }
        default:
            nil
        }
    }
}
