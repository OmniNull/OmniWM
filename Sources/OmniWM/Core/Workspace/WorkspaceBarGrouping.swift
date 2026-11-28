// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

enum WorkspaceBarAppKey: Equatable {
    case hosted(UInt64)
    case bundle(UInt64)
    case process(pid_t)

    static func hosted(appId: borrowing String) -> Self {
        .hosted(hash(appId.utf8, folding: false))
    }

    static func bundle(_ bundleId: borrowing String) -> Self? {
        let bytes = trimmed(bundleId.utf8)
        return bytes.isEmpty ? nil : .bundle(hash(bytes, folding: true))
    }

    static func sameBundle(_ first: borrowing String, _ second: borrowing String) -> Bool {
        trimmed(first.utf8).elementsEqual(trimmed(second.utf8)) { folded($0) == folded($1) }
    }

    private static func trimmed(_ bytes: String.UTF8View) -> Substring.UTF8View {
        guard let start = bytes.firstIndex(where: { !isSpace($0) }),
              let end = bytes.lastIndex(where: { !isSpace($0) })
        else { return bytes[bytes.endIndex...] }
        return bytes[start ... end]
    }

    private static func hash(_ bytes: some Sequence<UInt8>, folding: Bool) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in bytes {
            hash = (hash ^ UInt64(folding ? folded(byte) : byte)) &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    private static func folded(_ byte: UInt8) -> UInt8 {
        byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z") ? byte | 0x20 : byte
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || (byte >= 0x09 && byte <= 0x0D)
    }
}

@MainActor
protocol WorkspaceBarPillSource {
    func key(of member: Int) -> WorkspaceBarAppKey
    func isSameApp(_ member: Int, as first: Int) -> Bool
    func isHidden(_ member: Int) -> Bool
    func isFocused(_ member: Int) -> Bool
}

struct WorkspaceBarPill {
    let position: Int
    let first: Int
    let key: WorkspaceBarAppKey?
    var start = 0
    var count = 0
    var hiddenCount = 0
    var isFocused = false

    var isAppHidden: Bool {
        hiddenCount == count
    }

    struct Rank {
        let hidden: Bool
        let position: Int
    }

    static func sortsBefore(
        _ rank: Rank, named name: borrowing String, _ other: Rank, named otherName: borrowing String
    ) -> Bool {
        if rank.hidden != other.hidden { return !rank.hidden }
        if name != otherName { return name < otherName }
        return rank.position < other.position
    }
}

struct WorkspaceBarPillGrouping {
    private(set) var pills: [WorkspaceBarPill] = []
    private(set) var members: [Int] = []
    private var pillOfMember: [Int] = []
    private var nextSlot: [Int] = []

    @MainActor
    mutating func group(count: Int, deduplicating: Bool, source: some WorkspaceBarPillSource) {
        pills.removeAll(keepingCapacity: true)
        pillOfMember.removeAll(keepingCapacity: true)
        for member in 0 ..< count {
            let key = deduplicating ? source.key(of: member) : nil
            var pill = pills.endIndex
            if let key {
                for candidate in pills.indices
                    where pills[candidate].key == key && source.isSameApp(member, as: pills[candidate].first)
                {
                    pill = candidate
                    break
                }
            }
            if pill == pills.endIndex {
                pills.append(WorkspaceBarPill(position: pill, first: member, key: key))
            }
            pills[pill].count += 1
            if source.isHidden(member) { pills[pill].hiddenCount += 1 }
            if source.isFocused(member) { pills[pill].isFocused = true }
            pillOfMember.append(pill)
        }
        layOutMembers(count: count)
    }

    func members(of pill: borrowing WorkspaceBarPill) -> ArraySlice<Int> {
        members[pill.start ..< pill.start + pill.count]
    }

    private mutating func layOutMembers(count: Int) {
        nextSlot.removeAll(keepingCapacity: true)
        var start = 0
        for index in pills.indices {
            pills[index].start = start
            nextSlot.append(start)
            start += pills[index].count
        }
        members.removeAll(keepingCapacity: true)
        members.append(contentsOf: repeatElement(0, count: count))
        for member in 0 ..< count {
            let pill = pillOfMember[member]
            members[nextSlot[pill]] = member
            nextSlot[pill] += 1
        }
    }
}
