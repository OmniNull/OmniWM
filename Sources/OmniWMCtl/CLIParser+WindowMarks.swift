// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMIPC

extension CLIParser {
    static func parseWindowMarkRequest(id: String, arguments: [String]) throws -> IPCRequest {
        guard let actionToken = arguments.first,
              let action = IPCWindowMarkActionName(rawValue: actionToken)
        else {
            throw CLIParseError.usage(usageText)
        }

        if action == .list {
            guard arguments.count == 1 else {
                throw CLIParseError.usage(usageText)
            }
            return IPCRequest(id: id, windowMark: .list)
        }

        guard arguments.count == 2 else {
            throw CLIParseError.usage(usageText)
        }
        let name = arguments[1]
        let request: IPCWindowMarkRequest
        switch action {
        case .set:
            request = .set(name: name)
        case .focus:
            request = .focus(name: name)
        case .summon:
            request = .summon(name: name)
        case .remove:
            request = .remove(name: name)
        case .list:
            throw CLIParseError.usage(usageText)
        }
        return IPCRequest(id: id, windowMark: request)
    }
}
