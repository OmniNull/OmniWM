// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMScriptHost

extension ConfigScriptSnapshotWriter {
    var position: Int {
        bytes.count
    }

    mutating func patch(_ value: UInt16, at offset: Int) {
        bytes.withUnsafeMutableBytes { $0.storeBytes(of: value.littleEndian, toByteOffset: offset, as: UInt16.self) }
    }

    mutating func ratio(_ value: CGFloat) -> Bool {
        guard makeRoom(for: MemoryLayout<Double>.size) else { return false }
        appendLE(Double(value).bitPattern)
        return true
    }

    mutating func hex(_ value: UInt64) -> Bool {
        let digits = UInt64.bitWidth / 4
        guard makeRoom(for: digits, prefix: MemoryLayout<UInt32>.size) else { return false }
        appendLE(UInt32(digits))
        for shift in stride(from: UInt64.bitWidth - 4, through: 0, by: -4) {
            bytes.append(Self.hexDigits[Int(truncatingIfNeeded: value >> UInt64(shift)) & 0xF])
        }
        return true
    }

    mutating func uuid(_ value: UUID) -> Bool {
        let groups = [4, 2, 2, 2, 6]
        let length = MemoryLayout<uuid_t>.size * 2 + groups.count - 1
        guard makeRoom(for: length, prefix: MemoryLayout<UInt32>.size) else { return false }
        appendLE(UInt32(length))
        withUnsafeBytes(of: value.uuid) { source in
            var offset = 0
            for (group, size) in groups.enumerated() {
                if group > 0 { bytes.append(UInt8(ascii: "-")) }
                for byte in source[offset ..< offset + size] {
                    bytes.append(Self.hexDigits[Int(byte >> 4)])
                    bytes.append(Self.hexDigits[Int(byte & 0xF)])
                }
                offset += size
            }
        }
        return true
    }

    private static let hexDigits = Array("0123456789ABCDEF".utf8)
}

extension WMController {
    func appendScriptDwindle(
        in workspaceId: WorkspaceDescriptor.ID, session: ConfigScriptSession,
        to output: inout ConfigScriptSnapshotWriter
    ) {
        let manager = workspaceManager
        let engine: DwindleLayoutEngine
        switch manager.dwindleTreeAccess(for: workspaceId) {
        case .unavailable:
            return
        case .tooLarge:
            _ = output.row { _ in false }
            return
        case let .ready(ready):
            engine = ready
        }
        let windows = manager.windowQueries
        output.rowUnlessAbsent { row in
            guard row.uuid(workspaceId) else { return false }
            let count = row.position
            guard row.count(0) else { return false }
            var nodes: UInt16 = 0
            var hasher = Hasher()
            hasher.combine(session.id)
            let read = engine.readTree(
                in: workspaceId, hasher: hasher,
                admission: { windows.tiledAdmission(of: $0, in: workspaceId) },
                split: { orientation, ratio in
                    nodes &+= 1
                    let vertical = orientation == .vertical
                    return row.flag(UInt8(OMNI_CONFIG_DWINDLE_SPLIT))
                        && row.flag(UInt8(vertical ? OMNI_CONFIG_DWINDLE_VERTICAL : OMNI_CONFIG_DWINDLE_HORIZONTAL))
                        && row.ratio(ratio)
                },
                leaf: { tile, active in
                    nodes &+= 1
                    guard let size = UInt16(exactly: tile.count), let index = UInt16(exactly: active + 1),
                          row.flag(UInt8(OMNI_CONFIG_DWINDLE_LEAF)), row.count(index), row.count(size)
                    else { return false }
                    for member in tile.indices where !row.windowID(tile[member].token, session: session) {
                        return false
                    }
                    return true
                }
            )
            switch read {
            case .unavailable:
                return nil
            case .refused:
                return false
            case let .read(preselection, revision):
                row.patch(nodes, at: count)
                return row.flag(Self.scriptDirection(preselection)) && row.hex(revision)
            }
        }
    }

    private static func scriptDirection(_ direction: Direction?) -> UInt8 {
        switch direction {
        case nil: 0
        case .left: UInt8(OMNI_CONFIG_DWINDLE_LEFT)
        case .right: UInt8(OMNI_CONFIG_DWINDLE_RIGHT)
        case .up: UInt8(OMNI_CONFIG_DWINDLE_UP)
        case .down: UInt8(OMNI_CONFIG_DWINDLE_DOWN)
        }
    }
}
