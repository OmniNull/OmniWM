// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMAutomation
import OmniWMScriptHost

struct ConfigScriptWorkspaceRequest: Equatable, Sendable {
    enum Target: Equatable, Sendable {
        case address(WorkspaceTarget)
        case id(String)
    }

    enum Name: String, Sendable {
        case focusName = "focus-name"
        case moveToMonitor = "move-to-monitor"
        case rename
        case scroll
    }

    enum Action: Equatable, Sendable {
        case native(WorkspaceTargetAction)
        case scroll(offset: CGFloat, animate: Bool)
    }

    let name: Name
    let target: Target
    let action: Action
}

extension ConfigScriptWorkspaceRequest {
    init(_ request: borrowing omni_config_workspace_request) throws(ConfigScriptError) {
        guard let name = try Name(rawValue: Self.string(request.action)) else {
            throw Self.failure("unknown workspace action; use focus-name, move-to-monitor, rename or scroll")
        }
        let options = UnsafeBufferPointer(start: request.options, count: request.option_count)
        let argument: omni_config_field? = request.has_argument ? request.argument : nil
        self.name = name
        target = try Self.target(request.target)
        switch name {
        case .focusName:
            guard argument == nil,
                  options.isEmpty else { throw Self.failure("the focus-name action takes only a workspace") }
            action = .native(.focus)
        case .moveToMonitor:
            guard let argument, argument.kind == OMNI_CONFIG_STRING,
                  let direction = try Direction(rawValue: Self.string(argument.string_value))
            else {
                throw Self.failure("the move-to-monitor action needs a direction: left, right, up or down")
            }
            let force = try Self.booleanOption(
                "force", in: options, default: false,
                error: "the move-to-monitor options take only force = true or false"
            )
            action = .native(.moveToMonitor(direction, force: force))
        case .rename:
            guard let argument, argument.kind == OMNI_CONFIG_STRING, options.isEmpty else {
                throw Self.failure("the rename action needs a workspace and a display name")
            }
            let displayName = try Self.string(argument.string_value)
            guard !displayName.contains(where: \.isNewline) else {
                throw Self.failure("a workspace display name can't contain a line break")
            }
            action = .native(.rename(displayName))
        case .scroll:
            guard let argument, argument.kind == OMNI_CONFIG_NUMBER, argument.number_value.isFinite else {
                throw Self.failure("the scroll action needs a finite number of points")
            }
            let animate = try Self.booleanOption(
                "animate", in: options, default: true, error: "the scroll options take only animate = true or false"
            )
            action = .scroll(offset: CGFloat(argument.number_value), animate: animate)
        }
    }

    private static func target(_ field: borrowing omni_config_field) throws(ConfigScriptError) -> Target {
        let label = try string(field.name)
        switch field.kind {
        case OMNI_CONFIG_NUMBER where label.isEmpty:
            guard let number = Int(exactly: field.number_value),
                  let target = WorkspaceTarget(workspaceNumber: number)
            else {
                throw failure("a workspace number must be a positive whole number")
            }
            return .address(target)
        case OMNI_CONFIG_STRING where label.isEmpty:
            let text = try string(field.string_value)
            guard !text.isEmpty else { throw failure("a workspace name can't be empty") }
            return .address(WorkspaceTarget(resolvingInput: text))
        case OMNI_CONFIG_STRING where label == "id":
            guard let id = try UUID(uuidString: string(field.string_value)) else {
                throw failure("a workspace id must be an ID from a Flex read or event")
            }
            return .id(id.uuidString)
        default:
            throw failure("a workspace target is a name, a workspace number or { id = ... }")
        }
    }

    private static func booleanOption(
        _ key: String, in options: UnsafeBufferPointer<omni_config_field>,
        default defaultValue: Bool, error: String
    ) throws(ConfigScriptError) -> Bool {
        var value = defaultValue
        for option in options {
            guard try string(option.name) == key, option.kind == OMNI_CONFIG_BOOLEAN else {
                throw failure(error)
            }
            value = option.bool_value
        }
        return value
    }

    private static func string(_ span: omni_config_span) throws(ConfigScriptError) -> String {
        guard let string = String(bytes: UnsafeRawBufferPointer(start: span.data, count: span.length), encoding: .utf8)
        else {
            throw failure("workspace action words must be valid UTF-8")
        }
        return string
    }

    private static func failure(_ message: String) -> ConfigScriptError {
        ConfigScriptError(line: nil, message: message.prefix(1).uppercased() + message.dropFirst() + ".")
    }
}

extension WMController {
    func performConfigScriptWorkspace(
        _ request: borrowing ConfigScriptWorkspaceRequest, target: ConfigScriptTarget
    ) throws(ConfigScriptDispatchRefusal) -> ExternalCommandResult {
        if let refusal = configScriptAutomationRefusal(session: target.sessionID) { throw refusal }
        let rawWorkspaceID = try resolveConfigScriptWorkspace(request.target)
        switch request.action {
        case let .native(action):
            return try performConfigScriptWorkspaceAction(action, on: rawWorkspaceID)
        case let .scroll(offset, animate):
            guard let id = workspaceManager.workspaceId(for: rawWorkspaceID, createIfMissing: false) else {
                throw ConfigScriptDispatchRefusal(reason: "no workspace has that name or number")
            }
            return try niriLayoutHandler.scrollWorkspace(id, to: offset, animate: animate) ? .executed : .noChange
        }
    }

    private func performConfigScriptWorkspaceAction(
        _ action: WorkspaceTargetAction, on rawWorkspaceID: String
    ) throws(ConfigScriptDispatchRefusal) -> ExternalCommandResult {
        let result = performWorkspaceTargetAction(action, onWorkspaceNamed: rawWorkspaceID)
        switch result {
        case .executed,
             .noChange:
            return result
        case .workspaceAssignmentConflict:
            throw ConfigScriptDispatchRefusal(
                reason: "the workspace is assigned to another display; pass { force = true } to move it anyway"
            )
        case .workspaceStateConflict:
            throw ConfigScriptDispatchRefusal(
                reason: "native fullscreen, a hidden app, a scratchpad or pending focus can't move safely now"
            )
        case .notFound:
            let reason = switch action {
            case .focus: "the workspace can't be focused now"
            case let .moveToMonitor(direction, _): "there's no display \(direction.rawValue) of the workspace"
            case .rename: "the workspace isn't in Settings, so it has no label to change"
            }
            throw ConfigScriptDispatchRefusal(reason: reason)
        default:
            throw ConfigScriptDispatchRefusal(reason: "\(result)")
        }
    }

    private func resolveConfigScriptWorkspace(
        _ target: ConfigScriptWorkspaceRequest.Target
    ) throws(ConfigScriptDispatchRefusal) -> String {
        switch target {
        case let .id(id):
            guard let id = UUID(uuidString: id), let descriptor = workspaceManager.descriptor(for: id) else {
                throw ConfigScriptDispatchRefusal(reason: "no workspace has that ID")
            }
            return descriptor.name
        case let .address(address):
            switch WorkspaceTargetResolver(settings: settings, workspaceManager: workspaceManager).resolve(address) {
            case let .success(rawWorkspaceID):
                return rawWorkspaceID
            case .failure(.ambiguousDisplayName):
                throw ConfigScriptDispatchRefusal(reason: "more than one workspace has that name")
            case .failure(.notFound),
                 .failure(.invalidTarget):
                throw ConfigScriptDispatchRefusal(reason: "no workspace has that name or number")
            }
        }
    }
}
