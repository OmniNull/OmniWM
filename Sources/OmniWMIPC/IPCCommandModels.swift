// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import OmniWMAutomation

public struct IPCCommandRequest: Equatable, Sendable {
    public let command: IPCCommand

    public init(_ command: IPCCommand) {
        self.command = command
    }

    public init(name: IPCCommandName, argumentValues: [IPCCommandArgumentValue] = []) throws {
        command = try IPCCommand(name: name, argumentValues: argumentValues)
    }

    public var name: IPCCommandName {
        command.name
    }
}
