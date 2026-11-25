// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMIPC

@MainActor
struct IPCDwindleRequestExecutor {
    private let controller: WMController
    private let sessionToken: String

    init(controller: WMController, sessionToken: String) {
        self.controller = controller
        self.sessionToken = sessionToken
    }

    func response(for request: IPCDwindleRequest, id: String) -> IPCResponse {
        controller.noteUserAction()
        if let guardResult = controller.automationRefusal {
            return IPCApplicationBridge.response(for: guardResult, id: id, kind: .dwindle)
        }
        switch request.name {
        case .replace:
            switch replace(request.tree) {
            case .replaced:
                return .success(id: id, kind: .dwindle, status: .executed)
            case .unchanged:
                return .failure(id: id, kind: .dwindle, status: .ignored, code: .noChange)
            case let .refused(refusal):
                return .failure(id: id, kind: .dwindle, code: Self.code(for: refusal))
            }
        }
    }

    private func replace(_ tree: IPCDwindleTree) -> DwindleTreeReplacement {
        guard let workspaceId = UUID(uuidString: tree.workspaceId), let revision = Self.revision(tree.revision),
              tree.nodes.count <= DwindleTreeRequest.nodeLimit
        else { return .refused(.invalid) }
        var nodes: [DwindleTreeRequest.Node] = []
        var members: [WindowToken] = []
        nodes.reserveCapacity(tree.nodes.count)
        for node in tree.nodes {
            if let refusal = append(node, to: &nodes, members: &members) { return .refused(refusal) }
        }
        var seed = Hasher()
        seed.combine(sessionToken)
        let request = DwindleTreeRequest(
            workspaceId: workspaceId, revision: revision, preselection: tree.preselect.map(Direction.init(ipc:)),
            nodes: nodes, members: members
        )
        return controller.dwindleLayoutHandler.replaceTree(request, seed: seed)
    }

    private func append(
        _ node: IPCDwindleNode,
        to nodes: inout [DwindleTreeRequest.Node],
        members: inout [WindowToken]
    ) -> DwindleTreeRefusal? {
        switch node.kind {
        case .split:
            guard let orientation = node.orientation, let ratio = node.ratio, node.members == nil, node.active == nil
            else { return .invalid }
            nodes.append(.split(DwindleOrientation(ipc: orientation), ratio: ratio))
        case .leaf:
            guard let ids = node.members, let active = node.active, active > 0, active <= ids.count,
                  ids.count <= DwindleLayoutEngine.treeMemberLimit - members.count,
                  node.orientation == nil, node.ratio == nil
            else { return .invalid }
            let start = members.count
            for id in ids {
                guard let window = IPCWindowOpaqueID.decode(id, expectingSessionToken: sessionToken) else {
                    return .unknownWindow
                }
                members.append(WindowToken(pid: window.pid, windowId: window.windowId))
            }
            nodes.append(.leaf(members: start ..< members.count, active: active - 1))
        }
        return nil
    }

    private static func revision(_ text: String) -> UInt64? {
        guard text.utf8.count == UInt64.bitWidth / 4, text.allSatisfy(\.isHexDigit) else { return nil }
        return UInt64(text, radix: 16)
    }

    private static func code(for refusal: DwindleTreeRefusal) -> IPCErrorCode {
        switch refusal {
        case .invalid: .invalidArguments
        case .staleRevision: .staleRevision
        case .wrongWorkspace: .wrongWorkspace
        case .unknownWindow: .staleWindowId
        case .membership: .membershipMismatch
        case .ineligible: .ineligibleWindow
        case .busy: .busy
        case .focusConflict: .focusConflict
        case .doesNotFit: .doesNotFit
        }
    }
}
