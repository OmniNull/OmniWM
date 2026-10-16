// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMIPC

extension CLIParser {
    static func parseShellRequest(id: String, arguments: [String]) throws -> IPCRequest {
        guard let action = arguments.first.flatMap(IPCShellActionName.init(rawValue:)), arguments.count >= 2 else {
            throw CLIParseError.usage(usageText)
        }
        let key = arguments[1]
        let request: IPCShellRequest
        switch action {
        case .set:
            guard arguments.count >= 3 else { throw CLIParseError.usage(usageText) }
            request = .set(key: key, value: arguments.dropFirst(2).joined(separator: " "))
        case .unset:
            guard arguments.count == 2 else { throw CLIParseError.usage(usageText) }
            request = .unset(key: key)
        case .toggle:
            guard arguments.count == 2 else { throw CLIParseError.usage(usageText) }
            request = .toggle(widget: key)
        case .profile:
            guard arguments.count == 2 else { throw CLIParseError.usage(usageText) }
            request = .profile(name: key)
        case .theme:
            guard arguments.count <= 3 else { throw CLIParseError.usage(usageText) }
            request = .theme(name: key, scheme: arguments.count == 3 ? arguments[2] : nil)
        case .eject:
            guard arguments.count == 2 else { throw CLIParseError.usage(usageText) }
            request = .eject(widget: key)
        case .initialize:
            guard arguments.count == 2 else { throw CLIParseError.usage(usageText) }
            request = .initialize(widget: key)
        case .trigger:
            guard arguments.count >= 3 else { throw CLIParseError.usage(usageText) }
            let value = arguments.dropFirst(3).joined(separator: " ")
            request = .trigger(widget: key, name: arguments[2], value: arguments.count > 3 ? value : nil)
        }
        return IPCRequest(id: id, shell: request)
    }
}
