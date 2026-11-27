// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMAutomation

public enum IPCWindowActionName: String, Codable, CaseIterable, Equatable, Sendable {
    case focus
    case navigate
    case summonRight = "summon-right"
    case moveToWorkspace = "move-to-workspace"
    case close
    case moveColumnToFirst = "move-column-to-first"
    case moveColumnToLast = "move-column-to-last"
    case moveColumnToIndex = "move-column-to-index"
    case moveColumn = "move-column"
    case toggleContainerFullPrimarySpan = "toggle-container-full-primary-span"
    case setContainerPrimarySpan = "set-container-primary-span"
    case setWindowPrimarySpan = "set-window-primary-span"
    case cycleWindowPrimarySpan = "cycle-window-primary-span"
    case setWindowSecondarySpan = "set-window-secondary-span"
    case resetWindowSecondarySpan = "reset-window-secondary-span"
    case cycleWindowSecondarySpan = "cycle-window-secondary-span"
    case toggleColumnTabbed = "toggle-column-tabbed"
    case toggleFloating = "toggle-floating"
    case assignToScratchpad = "assign-to-scratchpad"
}

public enum IPCCycleDirection: String, Codable, CaseIterable, Equatable, Sendable {
    case forward
    case backward
}

public struct IPCWindowRequest: Codable, Equatable, Sendable {
    public let name: IPCWindowActionName
    public let windowId: String
    public let workspaceTarget: WorkspaceTarget?
    public let columnIndex: Int?
    public let direction: IPCDirection?
    public let change: IPCSizeChange?
    public let cycle: IPCCycleDirection?
    public let scratchpadIndex: Int?

    public init(
        name: IPCWindowActionName,
        windowId: String,
        workspaceTarget: WorkspaceTarget? = nil,
        columnIndex: Int? = nil,
        direction: IPCDirection? = nil,
        change: IPCSizeChange? = nil,
        cycle: IPCCycleDirection? = nil,
        scratchpadIndex: Int? = nil
    ) {
        self.name = name
        self.windowId = windowId
        self.workspaceTarget = workspaceTarget
        self.columnIndex = columnIndex
        self.direction = direction
        self.change = change
        self.cycle = cycle
        self.scratchpadIndex = scratchpadIndex
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case windowId
        case workspaceTarget
        case columnIndex
        case direction
        case change
        case cycle
        case scratchpadIndex
    }

    private static func requiredArgumentKey(for name: IPCWindowActionName) -> CodingKeys? {
        switch name {
        case .moveToWorkspace: .workspaceTarget
        case .moveColumnToIndex: .columnIndex
        case .moveColumn: .direction
        case .setContainerPrimarySpan,
             .setWindowPrimarySpan,
             .setWindowSecondarySpan: .change
        case .cycleWindowPrimarySpan,
             .cycleWindowSecondarySpan: .cycle
        case .assignToScratchpad: .scratchpadIndex
        case .focus,
             .navigate,
             .summonRight,
             .close,
             .moveColumnToFirst,
             .moveColumnToLast,
             .toggleContainerFullPrimarySpan,
             .resetWindowSecondarySpan,
             .toggleColumnTabbed,
             .toggleFloating:
            nil
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(IPCWindowActionName.self, forKey: .name)
        windowId = try container.decode(String.self, forKey: .windowId)
        workspaceTarget = try container.decodeIfPresent(WorkspaceTarget.self, forKey: .workspaceTarget)
        columnIndex = try container.decodeIfPresent(Int.self, forKey: .columnIndex)
        direction = try container.decodeIfPresent(IPCDirection.self, forKey: .direction)
        change = try container.decodeIfPresent(IPCSizeChange.self, forKey: .change)
        cycle = try container.decodeIfPresent(IPCCycleDirection.self, forKey: .cycle)
        scratchpadIndex = try container.decodeIfPresent(Int.self, forKey: .scratchpadIndex)

        let required = Self.requiredArgumentKey(for: name)
        let present: [CodingKeys: Bool] = [
            .workspaceTarget: workspaceTarget != nil,
            .columnIndex: columnIndex != nil,
            .direction: direction != nil,
            .change: change != nil,
            .cycle: cycle != nil,
            .scratchpadIndex: scratchpadIndex != nil
        ]
        for (key, isPresent) in present where isPresent != (key == required) {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "\(key.stringValue) is \(isPresent ? "rejected" : "required") by \(name.rawValue)"
            )
        }

        if let columnIndex, columnIndex < 1 {
            throw DecodingError.dataCorruptedError(
                forKey: .columnIndex,
                in: container,
                debugDescription: "columnIndex must be >= 1"
            )
        }

        if let scratchpadIndex, !IPCScratchpadSlots.range.contains(scratchpadIndex) {
            throw DecodingError.dataCorruptedError(
                forKey: .scratchpadIndex,
                in: container,
                debugDescription: "scratchpadIndex must be in \(IPCScratchpadSlots.range)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(windowId, forKey: .windowId)
        try container.encodeIfPresent(workspaceTarget, forKey: .workspaceTarget)
        try container.encodeIfPresent(columnIndex, forKey: .columnIndex)
        try container.encodeIfPresent(direction, forKey: .direction)
        try container.encodeIfPresent(change, forKey: .change)
        try container.encodeIfPresent(cycle, forKey: .cycle)
        try container.encodeIfPresent(scratchpadIndex, forKey: .scratchpadIndex)
    }
}

public enum IPCWindowOpaqueIDValidationResult: Equatable, Sendable {
    case valid(pid: Int32, windowId: Int)
    case stale
    case invalid
}

private struct Base64URLState {
    private static let alphabet: StaticString = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    private var bits: UInt16 = 0
    private var bitCount = 0

    mutating func append(_ byte: UInt8, into buffer: UnsafeMutableRawBufferPointer, at index: inout Int) {
        bits = (bits << 8) | UInt16(byte)
        bitCount += 8
        while bitCount >= 6 {
            bitCount -= 6
            buffer[index] = Self.alphabet.utf8Start[Int((bits >> bitCount) & 63)]
            index += 1
        }
    }

    func finish(into buffer: UnsafeMutableRawBufferPointer, at index: inout Int) {
        if bitCount > 0 {
            buffer[index] = Self.alphabet.utf8Start[Int((bits << (6 - bitCount)) & 63)]
            index += 1
        }
    }
}

public enum IPCWindowOpaqueID {
    public struct Address: Equatable, Sendable {
        public let sessionToken: String
        public let pid: Int32
        public let windowId: Int
    }

    public struct Encoder {
        private let prefix: [UInt8]
        private let state: Base64URLState

        public init(sessionToken: String) {
            var state = Base64URLState()
            var prefix = [UInt8](repeating: 0, count: 3 + (sessionToken.utf8.count + 1) * 8 / 6)
            prefix.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
                buffer[0] = UInt8(ascii: "o")
                buffer[1] = UInt8(ascii: "w")
                buffer[2] = UInt8(ascii: "_")
                var index = 3
                for byte in sessionToken.utf8 { state.append(byte, into: buffer, at: &index) }
                state.append(UInt8(ascii: ":"), into: buffer, at: &index)
            }
            self.prefix = prefix
            self.state = state
        }

        public func append(pid: Int32, windowId: Int, to data: inout Data) {
            withEncodedBytes(pid: pid, windowId: windowId) { prefix, suffix in
                data.append(contentsOf: prefix)
                data.append(contentsOf: suffix)
            }
        }

        public func append(pid: Int32, windowId: Int, to bytes: inout [UInt8]) {
            withEncodedBytes(pid: pid, windowId: windowId) { prefix, suffix in
                bytes.append(contentsOf: prefix)
                bytes.append(contentsOf: suffix)
            }
        }

        package func withEncodedBytes<R>(
            pid: Int32, windowId: Int, _ read: (UnsafeRawBufferPointer, UnsafeRawBufferPointer) -> R
        ) -> R {
            var decimal = InlineArray<32, UInt8>(repeating: 0)
            var start = decimal.count
            Self.prependDecimal(windowId, to: &decimal, at: &start)
            start -= 1
            decimal[start] = UInt8(ascii: ":")
            Self.prependDecimal(Int(pid), to: &decimal, at: &start)
            var state = state
            var suffix = InlineArray<44, UInt8>(repeating: 0)
            return withUnsafeMutableBytes(of: &suffix) { buffer in
                var count = 0
                for index in start ..< decimal.count { state.append(decimal[index], into: buffer, at: &count) }
                state.finish(into: buffer, at: &count)
                let tail = UnsafeRawBufferPointer(start: buffer.baseAddress, count: count)
                return prefix.withUnsafeBytes { read($0, tail) }
            }
        }

        private static func prependDecimal(_ value: Int, to bytes: inout InlineArray<32, UInt8>, at index: inout Int) {
            var magnitude = value.magnitude
            repeat {
                index -= 1
                bytes[index] = UInt8(ascii: "0") + UInt8(magnitude % 10)
                magnitude /= 10
            } while magnitude != 0
            if value < 0 {
                index -= 1
                bytes[index] = UInt8(ascii: "-")
            }
        }
    }

    public static func encode(pid: Int32, windowId: Int, sessionToken: String) -> String {
        var bytes = Data()
        Encoder(sessionToken: sessionToken).append(pid: pid, windowId: windowId, to: &bytes)
        return String(decoding: bytes, as: UTF8.self)
    }

    public static func validate(
        _ value: String,
        expectingSessionToken sessionToken: String
    ) -> IPCWindowOpaqueIDValidationResult {
        guard let decoded = decode(value) else {
            return .invalid
        }
        guard decoded.sessionToken == sessionToken else {
            return .stale
        }
        return .valid(pid: decoded.pid, windowId: decoded.windowId)
    }

    public static func decode(
        _ value: String,
        expectingSessionToken sessionToken: String
    ) -> (pid: Int32, windowId: Int)? {
        switch validate(value, expectingSessionToken: sessionToken) {
        case let .valid(pid, windowId):
            return (pid, windowId)
        case .stale,
             .invalid:
            return nil
        }
    }

    public static func decode(_ value: String) -> Address? {
        guard value.hasPrefix("ow_") else { return nil }
        let encoded = String(value.dropFirst(3))
        guard let data = base64URLDecoded(encoded),
              let payload = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        let bytes = payload.utf8
        guard let windowDelimiter = bytes.lastIndex(of: 0x3A),
              let pidDelimiter = bytes[..<windowDelimiter].lastIndex(of: 0x3A)
        else {
            return nil
        }

        let pidStart = bytes.index(after: pidDelimiter)
        let windowStart = bytes.index(after: windowDelimiter)
        guard let sessionToken = String(bytes: bytes[..<pidDelimiter], encoding: .utf8),
              let pidText = String(bytes: bytes[pidStart ..< windowDelimiter], encoding: .utf8),
              let windowText = String(bytes: bytes[windowStart...], encoding: .utf8),
              let pid = Int32(pidText),
              let windowId = Int(windowText)
        else {
            return nil
        }

        return Address(
            sessionToken: sessionToken,
            pid: pid,
            windowId: windowId
        )
    }

    private static func base64URLDecoded(_ value: String) -> Data? {
        let remainder = value.count % 4
        let padding = remainder == 0 ? "" : String(repeating: "=", count: 4 - remainder)
        let base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + padding
        return Data(base64Encoded: base64)
    }
}
