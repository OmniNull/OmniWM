// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMIPC

enum CLIArgumentParser {
    static func parseDirection(_ rawValue: String) throws -> IPCDirection {
        guard let direction = IPCDirection(rawValue: rawValue) else {
            throw CLIParseError.usage(CLIParser.usageText)
        }
        return direction
    }

    static func parsePositiveInteger(_ rawValue: String) throws -> Int {
        guard let value = Int(rawValue), value > 0 else {
            throw CLIParseError.usage(CLIParser.usageText)
        }
        return value
    }

    static func parsePositiveDouble(_ rawValue: String) throws -> Double {
        guard let value = Double(rawValue), value > 0 else {
            throw CLIParseError.usage(CLIParser.usageText)
        }
        return value
    }

    static func parseInitialContainerPrimarySpan(_ rawValue: String) throws -> Double {
        guard let value = Double(rawValue), value.isFinite, (0.05 ... 1.0).contains(value) else {
            throw CLIParseError.usage(CLIParser.usageText)
        }
        return value
    }

    static func parsePID(_ rawValue: String) throws -> Int32 {
        guard let value = Int32(rawValue), value > 0 else {
            throw CLIParseError.usage(CLIParser.usageText)
        }
        return value
    }
}
