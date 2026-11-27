// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMAutomation

public enum IPCWorkspaceActionName: String, Codable, Equatable, Sendable {
    case focusName = "focus-name"
    case moveToMonitor = "move-to-monitor"
    case rename
}

public enum IPCWorkspaceRequest: Equatable, Sendable {
    case focusName(target: WorkspaceTarget)
    case moveToMonitor(target: WorkspaceTarget, direction: IPCDirection, force: Bool = false)
    case rename(target: WorkspaceTarget, displayName: String)

    public var name: IPCWorkspaceActionName {
        switch self {
        case .focusName:
            .focusName
        case .moveToMonitor:
            .moveToMonitor
        case .rename:
            .rename
        }
    }

    public var target: WorkspaceTarget {
        switch self {
        case let .focusName(target),
             let .moveToMonitor(target, _, _),
             let .rename(target, _):
            target
        }
    }
}

extension IPCWorkspaceRequest: Codable {
    private enum CodingKeys: String, CodingKey {
        case name
        case workspaceTarget
        case direction
        case force
        case displayName
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(IPCWorkspaceActionName.self, forKey: .name)
        let target = try container.decode(WorkspaceTarget.self, forKey: .workspaceTarget)

        switch name {
        case .focusName:
            self = .focusName(target: target)
        case .moveToMonitor:
            self = .moveToMonitor(
                target: target,
                direction: try container.decode(IPCDirection.self, forKey: .direction),
                force: try container.decodeIfPresent(Bool.self, forKey: .force) ?? false
            )
        case .rename:
            self = .rename(
                target: target,
                displayName: try container.decode(String.self, forKey: .displayName)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(target, forKey: .workspaceTarget)

        switch self {
        case .focusName:
            break
        case let .moveToMonitor(_, direction, force):
            try container.encode(direction, forKey: .direction)
            try container.encode(force, forKey: .force)
        case let .rename(_, displayName):
            try container.encode(displayName, forKey: .displayName)
        }
    }
}
