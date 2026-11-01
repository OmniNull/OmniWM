// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

enum ShellNotificationsCommand: Equatable, Sendable {
    case refresh
    case dismissAll
    case cancelDismissAll
    case open(bundle: String)
    case dismiss(bundle: String, id: UUID)
    case reply(bundle: String, id: UUID, text: String)

    init?(words: [String]) {
        if words == ["refresh"] {
            self = .refresh
        } else if words == ["dismiss-all"] {
            self = .dismissAll
        } else if words == ["cancel-dismiss-all"] {
            self = .cancelDismissAll
        } else if words.count == 2, words[0] == "open", Self.validBundle(words[1]) {
            self = .open(bundle: words[1])
        } else if words.count == 3, words[0] == "dismiss", Self.validBundle(words[1]),
                  let id = Self.identifier(words[2])
        {
            self = .dismiss(bundle: words[1], id: id)
        } else if words.count == 4, words[0] == "reply", Self.validBundle(words[1]),
                  let id = Self.identifier(words[2]), let text = Self.replyText(words[3])
        {
            self = .reply(bundle: words[1], id: id, text: text)
        } else {
            return nil
        }
    }

    static func validBundle(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 255 && value.utf8.allSatisfy {
            (48 ... 57).contains($0) || (65 ... 90).contains($0) || (97 ... 122).contains($0)
                || $0 == 45 || $0 == 46 || $0 == 95
        }
    }

    private static func identifier(_ value: String) -> UUID? {
        guard let id = UUID(uuidString: value), value.lowercased() == id.uuidString.lowercased() else { return nil }
        return id
    }

    private static func replyText(_ value: String) -> String? {
        guard !value.isEmpty, value.utf8.count <= 8192, value.utf8.count.isMultiple(of: 2) else { return nil }
        let hex = Array(value.utf8)
        func nibble(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 48 ... 57: byte - 48
            case 65 ... 70: byte - 55
            case 97 ... 102: byte - 87
            default: nil
            }
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        for index in stride(from: 0, to: hex.count, by: 2) {
            guard let high = nibble(hex[index]), let low = nibble(hex[index + 1]) else { return nil }
            bytes.append(high << 4 | low)
        }
        guard let text = String(bytes: bytes, encoding: .utf8), !text.contains("\0"),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return text
    }
}
