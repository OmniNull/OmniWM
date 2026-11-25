// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

public enum IPCDwindleNodeKind: String, Codable, Equatable, Sendable {
    case split
    case leaf
}

public struct IPCDwindleNode: Codable, Equatable, Sendable {
    public let kind: IPCDwindleNodeKind
    public let orientation: IPCResizeAxis?
    public let ratio: Double?
    public let members: [String]?
    public let active: Int?

    public init(orientation: IPCResizeAxis, ratio: Double) {
        kind = .split
        self.orientation = orientation
        self.ratio = ratio
        members = nil
        active = nil
    }

    public init(members: [String], active: Int) {
        kind = .leaf
        orientation = nil
        ratio = nil
        self.members = members
        self.active = active
    }
}

public struct IPCDwindleTree: Codable, Equatable, Sendable {
    public let workspaceId: String
    public let revision: String
    public let preselect: IPCDirection?
    public let nodes: [IPCDwindleNode]

    public init(workspaceId: String, revision: String, preselect: IPCDirection?, nodes: [IPCDwindleNode]) {
        self.workspaceId = workspaceId
        self.revision = revision
        self.preselect = preselect
        self.nodes = nodes
    }
}

public struct IPCDwindleTreeQueryResult: Codable, Equatable, Sendable {
    public let workspace: IPCWorkspaceRef?
    public let tree: IPCDwindleTree?
    public let tooLarge: Bool

    public init(workspace: IPCWorkspaceRef?, tree: IPCDwindleTree?, tooLarge: Bool) {
        self.workspace = workspace
        self.tree = tree
        self.tooLarge = tooLarge
    }
}

public enum IPCDwindleActionName: String, Codable, CaseIterable, Equatable, Sendable {
    case replace
}

public struct IPCDwindleRequest: Codable, Equatable, Sendable {
    public let name: IPCDwindleActionName
    public let tree: IPCDwindleTree

    public init(name: IPCDwindleActionName, tree: IPCDwindleTree) {
        self.name = name
        self.tree = tree
    }
}

public struct IPCDwindleActionDescriptor: Codable, Equatable, Sendable {
    public let path: String
    public let name: IPCDwindleActionName
    public let summary: String
    public let arguments: [String]

    public init(path: String, name: IPCDwindleActionName, summary: String, arguments: [String] = []) {
        self.path = path
        self.name = name
        self.summary = summary
        self.arguments = arguments
    }
}
