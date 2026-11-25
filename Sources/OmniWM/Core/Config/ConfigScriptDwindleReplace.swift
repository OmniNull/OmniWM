// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMScriptHost

struct ConfigScriptDwindleReplace: Equatable, Sendable {
    let session: ConfigScriptSession?
    let request: DwindleTreeRequest

    init(tree: omni_config_dwindle_tree) throws(ConfigScriptError) {
        guard let workspaceId = UUID(uuidString: Self.string(tree.workspace_id)) else {
            throw ConfigScriptError(line: nil, message: "Expected the workspaceId of ctx.dwindle.")
        }
        let revisionBytes = Self.bytes(tree.revision)
        guard revisionBytes.count == UInt64.bitWidth / 4,
              revisionBytes.allSatisfy({ UInt8(ascii: "0") ... UInt8(ascii: "9") ~= $0
                      || UInt8(ascii: "A") ... UInt8(ascii: "F") ~= $0 || UInt8(ascii: "a") ... UInt8(ascii: "f") ~= $0
              }),
              let revision = UInt64(Self.string(tree.revision), radix: 16)
        else { throw ConfigScriptError(line: nil, message: "Expected the revision of ctx.dwindle.") }
        var members: [WindowToken] = []
        members.reserveCapacity(tree.member_count)
        var session: ConfigScriptSession?
        var mixed = false
        for index in 0 ..< tree.member_count {
            guard let id = ConfigScriptWindowID.decode(Self.bytes(tree.members[index])) else {
                throw ConfigScriptError(line: nil, message: "Expected a session-scoped window ID.")
            }
            mixed = mixed || session.map { $0 != id.session } == true
            session = id.session
            members.append(id.token)
        }
        var nodes: [DwindleTreeRequest.Node] = []
        nodes.reserveCapacity(tree.node_count)
        for index in 0 ..< tree.node_count {
            let node = tree.nodes[index]
            if node.kind == OMNI_CONFIG_DWINDLE_SPLIT {
                let orientation: DwindleOrientation = node.orientation == OMNI_CONFIG_DWINDLE_VERTICAL
                    ? .vertical : .horizontal
                nodes.append(.split(orientation, ratio: node.ratio))
            } else {
                let first = Int(node.first_member)
                nodes.append(.leaf(members: first ..< first + Int(node.member_count), active: Int(node.active) - 1))
            }
        }
        self.session = mixed ? nil : session
        request = DwindleTreeRequest(
            workspaceId: workspaceId, revision: revision, preselection: Self.directions[tree.preselect],
            nodes: nodes, members: members
        )
    }

    private static let directions: [UInt8: Direction] = [
        UInt8(OMNI_CONFIG_DWINDLE_LEFT): .left, UInt8(OMNI_CONFIG_DWINDLE_RIGHT): .right,
        UInt8(OMNI_CONFIG_DWINDLE_UP): .up, UInt8(OMNI_CONFIG_DWINDLE_DOWN): .down
    ]

    private static func bytes(_ span: omni_config_span) -> UnsafeRawBufferPointer {
        UnsafeRawBufferPointer(start: span.data, count: span.length)
    }

    private static func string(_ span: omni_config_span) -> String {
        String(decoding: bytes(span), as: UTF8.self)
    }
}

enum ConfigScriptDwindleOutcome: Equatable {
    case result(ExternalCommandResult)
    case refused(DwindleTreeRefusal)

    var externalResult: ExternalCommandResult {
        switch self {
        case let .result(result): result
        case .refused(.invalid): .invalidArguments
        case .refused(.unknownWindow): .staleWindowId
        case .refused(.wrongWorkspace): .ignoredLayoutMismatch
        case .refused(.staleRevision),
             .refused(.busy),
             .refused(.membership): .workspaceStateConflict
        case .refused(.ineligible),
             .refused(.focusConflict),
             .refused(.doesNotFit): .windowActionFailed
        }
    }
}

extension DwindleTreeRefusal {
    var reason: String {
        switch self {
        case .invalid: "the tree isn't one complete Dwindle tree within the limits"
        case .staleRevision: "the workspace changed since ctx.dwindle was read"
        case .wrongWorkspace: "its workspace isn't the shown Dwindle workspace"
        case .unknownWindow: "a window ID is unknown or from an earlier session"
        case .membership: "the tree must list each tiled window of the workspace once"
        case .ineligible: "a window is minimized, hidden, fullscreen, in a scratchpad or on another desktop"
        case .busy: "a tile drag, resize or workspace swipe is running, or Dwindle hasn't caught up yet"
        case .focusConflict: "the focused window must stay the shown tab of its group"
        case .doesNotFit: "the windows' minimum sizes don't fit the display"
        }
    }
}

extension WMController {
    func performConfigScriptDwindleReplace(
        _ replace: ConfigScriptDwindleReplace, target: ConfigScriptTarget
    ) -> ConfigScriptDwindleOutcome {
        guard target.sessionID == scriptSession.identity else { return .result(.staleWindowId) }
        if let automationRefusal { return .result(automationRefusal) }
        guard replace.request.members.isEmpty || replace.session == scriptSession.identity else {
            return .refused(.unknownWindow)
        }
        var seed = Hasher()
        seed.combine(scriptSession.identity.id)
        switch dwindleLayoutHandler.replaceTree(replace.request, seed: seed) {
        case .replaced: return .result(.executed)
        case .unchanged: return .result(.noChange)
        case let .refused(refusal): return .refused(refusal)
        }
    }
}
