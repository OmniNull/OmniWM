// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMScriptHost

struct ConfigScriptSnapshotWriter {
    let limit: Int
    var bytes: [UInt8] = []
    private var header = 0
    private var rows: UInt16 = 0
    private var truncated = false
    private(set) var framed = false
    private(set) var columned = false
    private(set) var detailed = false
    private var detailsTruncated = false
    private var detailStart: Int?
    private var detailBytes = 0
    var acceptsDetails: Bool {
        detailed && !detailsTruncated
    }

    private var frameBytes = 0
    private var columnBytes = 0

    init(limit: Int) {
        self.limit = limit
    }

    mutating func makeRoom(for payload: Int, prefix: Int = 0) -> Bool {
        guard payload <= remaining - prefix else { return false }
        reserve(payload + prefix)
        return true
    }

    private mutating func reserve(_ count: Int) {
        if count > bytes.capacity - bytes.count { bytes.reserveCapacity(limit) }
    }

    private var remaining: Int {
        if let detailStart {
            let prefixes = (ConfigScriptSnapshot.rowLimit - Int(rows) - 1) * MemoryLayout<UInt16>.size
            return ConfigScriptSnapshot.detailByteLimit - prefixes - detailBytes - (bytes.count - detailStart)
        }
        return ConfigScriptSnapshot.byteLimit - (bytes.count - header - frameBytes - columnBytes - detailBytes)
    }

    mutating func start(
        _ kind: ConfigScriptReads,
        framed: Bool = false,
        columned: Bool = false,
        detailed: Bool = false
    ) {
        start(tag: UInt8(truncatingIfNeeded: kind.rawValue), framed: framed, columned: columned, detailed: detailed)
    }

    mutating func start(tag: UInt8, framed: Bool = false, columned: Bool = false, detailed: Bool = false) {
        header = bytes.count
        rows = 0
        truncated = false
        self.framed = framed
        self.columned = columned
        self.detailed = detailed
        detailsTruncated = false
        detailBytes = 0
        frameBytes = 0
        columnBytes = 0
        reserve(MemoryLayout<UInt64>.size)
        appendLE(UInt64(tag))
    }

    mutating func finish() {
        let length = UInt32(bytes.count - header - MemoryLayout<UInt64>.size)
        let section = (truncated ? OMNI_CONFIG_SECTION_TRUNCATED : 0) | (framed ? OMNI_CONFIG_SECTION_FRAMES : 0)
            | (columned ? OMNI_CONFIG_SECTION_COLUMNS : 0)
            | (detailed ? OMNI_CONFIG_SECTION_DETAILS : 0)
            | (detailsTruncated ? OMNI_CONFIG_SECTION_DETAILS_TRUNCATED : 0)
        let flags = UInt64(bytes[header]) | (UInt64(section) << 8)
        let value = flags | (UInt64(rows) << 16) | (UInt64(length) << 32)
        bytes.withUnsafeMutableBytes { $0.storeBytes(of: value.littleEndian, toByteOffset: header, as: UInt64.self) }
    }

    mutating func rowUnlessAbsent(_ write: (inout Self) -> Bool?) {
        let wasTruncated = truncated
        var absent = false
        _ = row { row in
            guard let stored = write(&row) else {
                absent = true
                return false
            }
            return stored
        }
        if absent { truncated = wasTruncated }
    }

    mutating func row(_ write: (inout Self) -> Bool) -> Bool {
        guard rows < ConfigScriptSnapshot.rowLimit else {
            truncated = true
            return false
        }
        let start = bytes.count
        let frames = frameBytes
        let columns = columnBytes
        let details = detailBytes
        guard write(&self) else {
            bytes.removeSubrange(start...)
            frameBytes = frames
            columnBytes = columns
            detailBytes = details
            truncated = true
            return false
        }
        rows += 1
        return true
    }

    mutating func details(_ write: (inout Self) -> Bool) {
        let offset = bytes.count
        let prefix = MemoryLayout<UInt16>.size
        reserve(prefix)
        appendLE(UInt16.zero)
        detailBytes += prefix
        guard !detailsTruncated else { return }
        let start = bytes.count
        detailStart = start
        let stored = write(&self)
        detailStart = nil
        if stored {
            let length = bytes.count - start
            patch(UInt16(length), at: offset)
            detailBytes += length
        } else {
            bytes.removeSubrange(start...)
            detailsTruncated = true
        }
    }

    mutating func detailValue(_ value: some FixedWidthInteger) -> Bool {
        guard makeRoom(for: MemoryLayout.size(ofValue: value)) else { return false }
        appendLE(value)
        return true
    }

    mutating func detailNumber(_ value: CGFloat) -> Bool {
        detailValue(Double(value).bitPattern)
    }

    mutating func detailEdges(_ left: CGFloat, _ right: CGFloat, _ top: CGFloat, _ bottom: CGFloat) -> Bool {
        detailNumber(left) && detailNumber(right) && detailNumber(top) && detailNumber(bottom)
    }

    mutating func detailRect(_ rect: CGRect) -> Bool {
        detailNumber(rect.origin.x) && detailNumber(rect.origin.y) && detailNumber(rect.size.width)
            && detailNumber(rect.size.height)
    }

    mutating func column(_ number: UInt16) {
        reserve(ConfigScriptSnapshot.columnBytes)
        appendLE(number)
        columnBytes += ConfigScriptSnapshot.columnBytes
    }

    mutating func frame(_ frame: CGRect?) {
        reserve(ConfigScriptSnapshot.windowFrameBytes)
        bytes.append(frame == nil ? 0 : UInt8(OMNI_CONFIG_FRAME_PRESENT))
        frameBytes += MemoryLayout<UInt8>.size
        if let frame { appendRect(frame) }
    }

    mutating func frames(_ frame: CGRect, visible: CGRect) {
        reserve(ConfigScriptSnapshot.monitorFrameBytes)
        appendRect(frame)
        appendRect(visible)
    }

    private mutating func appendRect(_ rect: CGRect) {
        appendLE(Double(rect.origin.x).bitPattern)
        appendLE(Double(rect.origin.y).bitPattern)
        appendLE(Double(rect.size.width).bitPattern)
        appendLE(Double(rect.size.height).bitPattern)
        frameBytes += MemoryLayout<CGRect>.size
    }

    mutating func string(_ value: borrowing String?) -> Bool {
        if value != nil { return string(value!) }
        guard makeRoom(for: MemoryLayout<UInt32>.size) else { return false }
        appendLE(UInt32.max)
        return true
    }

    mutating func string(_ value: borrowing String) -> Bool {
        let prefix = MemoryLayout<UInt32>.size
        if let stored = value.utf8.withContiguousStorageIfAvailable({ source in
            guard makeRoom(for: source.count, prefix: prefix) else { return false }
            appendLE(UInt32(source.count))
            bytes.append(contentsOf: source)
            return true
        }) { return stored }
        guard makeRoom(for: prefix) else { return false }
        let offset = bytes.count
        appendLE(UInt32.zero)
        for byte in value.utf8 {
            guard flag(byte) else { return false }
        }
        let length = UInt32(bytes.count - offset - prefix)
        bytes.withUnsafeMutableBytes { $0.storeBytes(of: length.littleEndian, toByteOffset: offset, as: UInt32.self) }
        return true
    }

    mutating func string(_ id: UUID) -> Bool {
        let length = 2 * MemoryLayout<uuid_t>.size + 4
        guard makeRoom(for: length, prefix: MemoryLayout<UInt32>.size) else { return false }
        appendLE(UInt32(length))
        withUnsafeBytes(of: id.uuid) { raw in
            for index in raw.indices {
                if index == 4 || index == 6 || index == 8 || index == 10 { bytes.append(UInt8(ascii: "-")) }
                bytes.append(Self.hexDigit(raw[index] >> 4))
                bytes.append(Self.hexDigit(raw[index] & 0x0F))
            }
        }
        return true
    }

    private static func hexDigit(_ nibble: UInt8) -> UInt8 {
        nibble < 10 ? UInt8(ascii: "0") + nibble : UInt8(ascii: "A") + nibble - 10
    }

    mutating func windowID(_ token: WindowToken, session: ConfigScriptSession) -> Bool {
        ConfigScriptWindowID.withBytes(token, session: session) { id in
            guard makeRoom(for: id.count, prefix: MemoryLayout<UInt32>.size) else { return false }
            appendLE(UInt32(id.count))
            bytes.append(contentsOf: id)
            return true
        }
    }

    mutating func flag(_ value: UInt8) -> Bool {
        guard makeRoom(for: MemoryLayout<UInt8>.size) else { return false }
        bytes.append(value)
        return true
    }

    mutating func count(_ value: UInt16) -> Bool {
        guard makeRoom(for: MemoryLayout<UInt16>.size) else { return false }
        appendLE(value)
        return true
    }

    mutating func appendLE(_ value: some FixedWidthInteger) {
        withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
    }

    #if OMNIWM_CONFIG_CALLBACK_TRACE
        var rowCount: Int {
            Int(rows)
        }
    #endif
}
