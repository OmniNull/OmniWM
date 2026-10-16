// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit

enum ShellClipboardContent: Equatable, Sendable {
    case text(String)
    case url(URL)
    case data(Data, uti: String)
}

@MainActor
enum ShellClipboard {
    static func copy(_ content: ShellClipboardContent, to pasteboard: NSPasteboard = .general) -> Bool {
        let item = NSPasteboardItem()
        let prepared: Bool
        switch content {
        case let .text(text):
            guard text.utf8.count <= ShellDropSnapshot.inlineByteLimit else { return false }
            prepared = item.setString(text, forType: .string)
        case let .url(url):
            guard !url.isFileURL else { return false }
            prepared = item.setString(url.absoluteString, forType: .URL) && item.setString(
                url.absoluteString,
                forType: .string
            )
        case let .data(data, uti):
            guard data.count <= ShellDropSnapshot.inlineByteLimit, !uti.isEmpty else { return false }
            prepared = item.setData(data, forType: NSPasteboard.PasteboardType(uti))
        }
        guard prepared else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }

    static func read(from pasteboard: NSPasteboard = .general) throws -> [ShellDropItem] {
        guard pasteboard.accessBehavior != .alwaysDeny else { throw ShellResourceFailure("clipboard_denied") }
        guard !(pasteboard.pasteboardItems ?? []).isEmpty else { return [] }
        return try ShellDropSnapshot.capture(pasteboard, accepts: .all, includePromises: false).items
    }
}

extension ShellResourceStore {
    func clipboardContent(
        _ resource: ShellResourceID,
        owner: ShellServiceOwner,
        operation: ShellResourceOperation
    ) throws -> ShellClipboardContent {
        guard operation.isActive else { throw ShellResourceFailure("cancelled") }
        let pin = try retain([resource], owner: owner)
        defer { release(pin) }
        guard let value = pin.values.first, let metadata = catalog.metadata(resource, owner: owner) else {
            throw ShellResourceFailure("resource_unavailable")
        }
        switch value {
        case .file:
            return .data(
                Data(try resourceBytes(value, limit: 16 << 20, operation: operation)),
                uti: metadata.descriptor.uti
            )
        case let .text(text):
            guard text.utf8.count <= 16 << 20 else { throw ShellResourceFailure("clipboard_too_large") }
            return .text(text)
        case let .url(url): return .url(url)
        }
    }
}
