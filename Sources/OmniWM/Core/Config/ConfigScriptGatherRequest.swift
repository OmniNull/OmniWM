// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import OmniWMScriptHost

struct ConfigScriptGatherRequest: Equatable, Sendable {
    let session: ConfigScriptSession?
    let tokens: [WindowToken]
    let reach: NiriGatherReach
    let repeated: Bool

    static let action = "gather"
    static let reaches: [(word: String, reach: NiriGatherReach)] = [
        ("workspace", .workspace), ("monitor", .monitor), ("all", .all)
    ]

    static func matches(_ words: UnsafeBufferPointer<omni_config_span>) -> Bool {
        words.count > 2 && bytes(words[0]).elementsEqual(action.utf8)
    }

    init(words: UnsafeBufferPointer<omni_config_span>) throws(ConfigScriptError) {
        let reachWord = Self.bytes(words[1])
        guard let reach = Self.reaches.first(where: { $0.word.utf8.elementsEqual(reachWord) })?.reach else {
            throw ConfigScriptError(line: nil, message: "gather reaches \"workspace\", \"monitor\" or \"all\".")
        }
        var tokens: [WindowToken] = []
        tokens.reserveCapacity(words.count - 2)
        var session: ConfigScriptSession?
        var mixed = false
        for word in words.dropFirst(2) {
            guard let id = ConfigScriptWindowID.decode(Self.bytes(word)) else {
                throw ConfigScriptError(line: nil, message: "Expected a session-scoped window ID.")
            }
            mixed = mixed || session.map { $0 != id.session } == true
            session = id.session
            tokens.append(id.token)
        }
        self.session = mixed ? nil : session
        self.tokens = tokens
        self.reach = reach
        repeated = tokens.indices.contains { index in tokens[..<index].contains(tokens[index]) }
    }

    private static func bytes(_ span: omni_config_span) -> UnsafeRawBufferPointer {
        UnsafeRawBufferPointer(start: span.data, count: span.length)
    }
}

extension WMController {
    func performConfigScriptGather(
        _ gather: ConfigScriptGatherRequest, target: ConfigScriptTarget
    ) -> ExternalCommandResult {
        guard target.sessionID == scriptSession.identity else { return .staleWindowId }
        if let automationRefusal { return automationRefusal }
        guard gather.session == scriptSession.identity else { return .staleWindowId }
        guard !gather.repeated else { return .invalidArguments }
        let handler = niriLayoutHandler
        guard let destination = handler.gatherDestination(), destination.workspaceId == target.workspaceId else {
            return .workspaceStateConflict
        }
        switch handler.gatherWindows(gather.tokens, from: gather.reach, into: destination) {
        case .gathered: return .executed
        case .unchanged: return .noChange
        case .refused(.unsupportedLayout): return .ignoredLayoutMismatch
        case .refused(.destinationUnavailable): return .workspaceStateConflict
        case .refused(.windows),
             .refused(.doesNotFit): return .windowActionFailed
        }
    }
}
