// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

struct ScratchpadState {
    private(set) var membersBySlot: [ScratchpadIndex: [WindowToken]] = [:]
    private(set) var revealedIndex: ScratchpadIndex?

    mutating func assign(_ token: WindowToken, to index: ScratchpadIndex?) {
        for (slot, members) in membersBySlot where members.contains(token) {
            guard slot != index else { return }
            let remaining = members.filter { $0 != token }
            membersBySlot[slot] = remaining.isEmpty ? nil : remaining
        }
        if let index {
            membersBySlot[index, default: []].append(token)
        }
        if let revealed = revealedIndex, membersBySlot[revealed] == nil {
            revealedIndex = nil
        }
    }

    mutating func rekey(from oldToken: WindowToken, to newToken: WindowToken) {
        guard oldToken != newToken else { return }
        for (slot, members) in membersBySlot {
            guard let position = members.firstIndex(of: oldToken) else { continue }
            membersBySlot[slot]?[position] = newToken
        }
    }

    mutating func reveal(_ index: ScratchpadIndex?) {
        revealedIndex = index.flatMap { membersBySlot[$0] == nil ? nil : $0 }
    }
}
