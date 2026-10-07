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

    static func parseResizeAxis(_ rawValue: String) throws -> IPCResizeAxis {
        guard let axis = IPCResizeAxis(rawValue: rawValue) else {
            throw CLIParseError.usage(CLIParser.usageText)
        }
        return axis
    }

    static func parseScratchpadIndex(_ rawValue: String) throws -> Int {
        guard let index = Int(rawValue), IPCScratchpadSlots.range.contains(index) else {
            throw CLIParseError.usage(CLIParser.usageText)
        }
        return index
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

    static func parseResizeOperation(_ rawValue: String) throws -> IPCResizeOperation {
        guard let operation = IPCResizeOperation(rawValue: rawValue) else {
            throw CLIParseError.usage(CLIParser.usageText)
        }
        return operation
    }

    static func parseWorkspaceLayout(_ rawValue: String) throws -> IPCWorkspaceLayout {
        guard let layout = IPCWorkspaceLayout(rawValue: rawValue) else {
            throw CLIParseError.usage(CLIParser.usageText)
        }
        return layout
    }

    static func parsePaletteMode(_ rawValue: String) throws -> IPCCommandPaletteMode {
        guard let mode = IPCCommandPaletteMode(rawValue: rawValue) else {
            throw CLIParseError.usage(CLIParser.usageText)
        }
        return mode
    }

    static func parseSizeChange(_ rawValue: String) throws -> IPCSizeChange {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CLIParseError.usage(CLIParser.usageText)
        }

        let isProportion = trimmed.hasSuffix("%")
        let numericText = isProportion ? String(trimmed.dropLast()) : trimmed
        guard let value = Double(numericText), value.isFinite else {
            throw CLIParseError.usage(CLIParser.usageText)
        }

        if trimmed.hasPrefix("+") || trimmed.hasPrefix("-") {
            return isProportion ? .adjustProportion(value) : .adjustFixed(value)
        }
        return isProportion ? .setProportion(value) : .setFixed(value)
    }

    static func parseCommandArgumentValue(
        _ pair: (IPCCommandArgumentDescriptor, String)
    ) throws -> IPCCommandArgumentValue {
        let (descriptor, token) = pair

        switch descriptor.kind {
        case .direction:
            return .direction(try parseDirection(token))
        case .workspaceNumber,
             .columnIndex,
             .windowIndex:
            return .integer(try parsePositiveInteger(token))
        case .scratchpadIndex:
            return .integer(try parseScratchpadIndex(token))
        case .layout:
            return .layout(try parseWorkspaceLayout(token))
        case .paletteMode:
            return .paletteMode(try parsePaletteMode(token))
        case .resizeAxis:
            return .resizeAxis(try parseResizeAxis(token))
        case .resizeOperation:
            return .resizeOperation(try parseResizeOperation(token))
        case .sizeChange:
            return .sizeChange(try parseSizeChange(token))
        }
    }
}
