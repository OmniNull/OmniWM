// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import UniformTypeIdentifiers

struct ShellDropTypes: OptionSet, Sendable {
    let rawValue: UInt8
    static let file = Self(rawValue: 1)
    static let url = Self(rawValue: 2)
    static let text = Self(rawValue: 4)
    static let image = Self(rawValue: 8)
    static let all: Self = [.file, .url, .text, .image]
}

struct ShellDropItem: Sendable {
    let name: String
    let kind: String
    let uti: String
    let source: ShellResourceStore.Source
}

@MainActor
struct ShellDropSnapshot {
    static let inlineByteLimit = 16 << 20
    var items: [ShellDropItem] = []
    var promises: [NSFilePromiseReceiver] = []

    static var registeredTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, .URL, .string, .png, .tiff] + NSFilePromiseReceiver.readableDraggedTypes
            .map { NSPasteboard.PasteboardType($0) }
    }

    static func types(_ pasteboard: NSPasteboard) -> ShellDropTypes {
        let types = Set(pasteboard.types ?? [])
        var result: ShellDropTypes = []
        if types.contains(.fileURL) || types
            .contains(where: { NSFilePromiseReceiver.readableDraggedTypes.contains($0.rawValue) })
        {
            result.insert(.file)
        }
        if types.contains(.URL) { result.insert(.url) }
        if types.contains(.string) { result.insert(.text) }
        if types.contains(.png) || types.contains(.tiff) { result.insert(.image) }
        if result.contains(.file) {
            let receivers = pasteboard
                .readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] ?? []
            if receivers.contains(where: isImagePromise) || (pasteboard.pasteboardItems ?? []).contains(where: {
                guard let string = $0.string(forType: .fileURL), let url = URL(string: string) else { return false }
                return UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
            }) { result.insert(.image) }
        }
        return result
    }

    static func capture(
        _ pasteboard: NSPasteboard,
        accepts: ShellDropTypes,
        includePromises: Bool = true
    ) throws -> Self {
        var snapshot = Self()
        var bytes = 0
        let items = pasteboard.pasteboardItems ?? []
        let urls = pasteboard.readObjects(forClasses: [NSURL.self, NSPasteboardItem.self], options: nil) ?? []
        let receivers = includePromises && (accepts.contains(.file) || accepts.contains(.image))
            ? pasteboard
            .readObjects(forClasses: [NSFilePromiseReceiver.self, NSPasteboardItem.self], options: nil) ?? [] : []
        guard urls.count == items.count, receivers.isEmpty || receivers.count == items.count else {
            throw ShellResourceFailure("pasteboard representations do not match their items")
        }
        for (index, item) in items.enumerated() {
            try snapshot.append(
                item,
                url: urls[index] as? URL,
                receiver: receivers.isEmpty ? nil : receivers[index] as? NSFilePromiseReceiver,
                accepts: accepts,
                bytes: &bytes
            )
            guard snapshot.items.count + snapshot.promises.count <= ShellFilePromiseBatch.itemLimit
            else { throw ShellResourceFailure("drop exceeds 32 items") }
        }
        guard !snapshot.items.isEmpty || !snapshot.promises.isEmpty
        else { throw ShellResourceFailure("drop has no supported items") }
        return snapshot
    }

    private mutating func append(
        _ item: NSPasteboardItem,
        url: URL?,
        receiver: NSFilePromiseReceiver?,
        accepts: ShellDropTypes,
        bytes: inout Int
    ) throws {
        if let receiver,
           accepts.contains(.file) || accepts.contains(.image) && Self.isImagePromise(receiver)
        {
            promises.append(receiver)
        } else if let url, url.isFileURL,
                  accepts.contains(.file) || accepts
                      .contains(.image) && UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
        {
            let type = UTType(filenameExtension: url.pathExtension)
            items.append(ShellDropItem(
                name: url.lastPathComponent,
                kind: "file",
                uti: type?.identifier ?? UTType.data.identifier,
                source: .file(url)
            ))
        } else if let value = try Self.inlineItem(item, url: url, accepts: accepts, bytes: &bytes) {
            items.append(value)
        }
    }

    private static func inlineItem(
        _ item: NSPasteboardItem,
        url: URL?,
        accepts: ShellDropTypes,
        bytes: inout Int
    ) throws -> ShellDropItem? {
        if accepts.contains(.url), let url, !url.isFileURL, let scheme = url.scheme, !scheme.isEmpty {
            let string = url.absoluteString
            guard string.utf8.count <= inlineByteLimit - bytes
            else { throw ShellResourceFailure("inline drop data exceeds 16 MiB") }
            bytes += string.utf8.count
            return ShellDropItem(
                name: String(string.prefix(256)),
                kind: "url",
                uti: UTType.url.identifier,
                source: .url(url)
            )
        } else if accepts.contains(.image), let type = item.availableType(from: [.png, .tiff]),
                  let data = item.data(forType: type)
        {
            guard data.count <= inlineByteLimit - bytes
            else { throw ShellResourceFailure("inline drop data exceeds 16 MiB") }
            bytes += data.count
            return ShellDropItem(
                name: type == .png ? "Image.png" : "Image.tiff",
                kind: "image",
                uti: type == .png ? UTType.png.identifier : UTType.tiff.identifier,
                source: .bytes(data)
            )
        } else if accepts.contains(.text), let text = item.string(forType: .string) ?? url?.absoluteString {
            guard text.utf8.count <= inlineByteLimit - bytes
            else { throw ShellResourceFailure("inline drop data exceeds 16 MiB") }
            bytes += text.utf8.count
            return ShellDropItem(
                name: "Text",
                kind: "text",
                uti: UTType.utf8PlainText.identifier,
                source: .text(text)
            )
        }
        return nil
    }

    private static func isImagePromise(_ receiver: NSFilePromiseReceiver) -> Bool {
        !receiver.fileTypes.isEmpty && receiver.fileTypes.allSatisfy { UTType($0)?.conforms(to: .image) == true }
    }
}

@MainActor
final class ShellFilePromiseSession {
    let receivers: [NSFilePromiseReceiver]
    let batch: ShellFilePromiseBatch
    private let readerQueue: OperationQueue
    private var started = false

    init(receivers: [NSFilePromiseReceiver], batch: ShellFilePromiseBatch, readerQueue: OperationQueue) {
        self.receivers = receivers
        self.batch = batch
        self.readerQueue = readerQueue
    }

    func start() throws -> [ShellFilePromiseBatch.Item] {
        guard !started else { throw ShellResourceFailure("file promises were already started") }
        guard batch.operation.isActive else { throw ShellResourceFailure("cancelled") }
        started = true
        for (index, receiver) in receivers.enumerated() {
            let receive: @Sendable (URL, (any Error)?) -> Void = { [batch] url, error in
                batch.receive(receiver: index, url: url, error: error?.localizedDescription)
            }
            receiver.receivePromisedFiles(
                atDestination: batch.directory,
                options: [:],
                operationQueue: readerQueue,
                reader: receive
            )
        }
        return try batch.configure(names: receivers.map(\.fileNames), types: receivers.map(\.fileTypes))
    }
}
