// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

enum ClipboardContentKind: String, Codable, Hashable, Sendable {
    case text
    case richText
    case html
    case image
    case fileURL
    case other
}

struct ClipboardHistoryConfiguration: Equatable, Sendable {
    static let fileName = "clipboard-history.json"

    var isEnabled: Bool
    var maxItems: Int
    var maxItemBytes: Int
    var maxTotalBytes: Int
    var storageDirectory: URL
    var ignoredTypes: [String]

    init(
        isEnabled: Bool,
        maxItems: Int,
        maxItemBytes: Int,
        maxTotalBytes: Int,
        storageDirectory: URL,
        ignoredTypes: [String] = []
    ) {
        self.isEnabled = isEnabled
        self.maxItems = maxItems
        self.maxItemBytes = maxItemBytes
        self.maxTotalBytes = maxTotalBytes
        self.storageDirectory = storageDirectory
        self.ignoredTypes = ignoredTypes
    }

    var storageURL: URL {
        storageDirectory.appendingPathComponent(Self.fileName, isDirectory: false)
    }
}

struct ClipboardPaletteItem: Identifiable, Equatable, Hashable, Sendable {
    let id: UUID
    let title: String
    let subtitle: String
    let kind: ClipboardContentKind
    let sourceBundleIdentifier: String?
    let lastCopiedAt: Date
    let numberOfCopies: Int
    let byteCount: Int
    let isPinned: Bool
    let searchText: String
    let canPastePlainText: Bool

    init(
        id: UUID,
        title: String,
        subtitle: String,
        kind: ClipboardContentKind,
        sourceBundleIdentifier: String?,
        lastCopiedAt: Date,
        numberOfCopies: Int,
        byteCount: Int,
        isPinned: Bool = false,
        searchText: String = "",
        canPastePlainText: Bool = false
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.kind = kind
        self.sourceBundleIdentifier = sourceBundleIdentifier
        self.lastCopiedAt = lastCopiedAt
        self.numberOfCopies = numberOfCopies
        self.byteCount = byteCount
        self.isPinned = isPinned
        self.searchText = searchText
        self.canPastePlainText = canPastePlainText
    }
}

enum ClipboardPalettePreview: Equatable, Sendable {
    case text(String)
    case image(Data)
}

struct ClipboardHistoryContent: Codable, Equatable, Sendable {
    let itemIndex: Int
    let type: String
    let kind: ClipboardContentKind
    let data: Data
}

struct ClipboardHistoryItem: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var contents: [ClipboardHistoryContent]
    var title: String
    var sourceBundleIdentifier: String?
    var firstCopiedAt: Date
    var lastCopiedAt: Date
    var numberOfCopies: Int
    var digest: String
    var byteCount: Int
    var kind: ClipboardContentKind
    var pinnedAt: Date?
    var derivedText: String?
    var recognizedText: String?

    var isPinned: Bool {
        pinnedAt != nil
    }

    var paletteItem: ClipboardPaletteItem {
        ClipboardPaletteItem(
            id: id,
            title: title,
            subtitle: Self.subtitle(
                sourceBundleIdentifier: sourceBundleIdentifier,
                lastCopiedAt: lastCopiedAt,
                numberOfCopies: numberOfCopies,
                byteCount: byteCount
            ),
            kind: kind,
            sourceBundleIdentifier: sourceBundleIdentifier,
            lastCopiedAt: lastCopiedAt,
            numberOfCopies: numberOfCopies,
            byteCount: byteCount,
            isPinned: isPinned,
            searchText: [derivedText, recognizedText].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " "),
            canPastePlainText: contents.contains { $0.kind == .text } || derivedText != nil
        )
    }

    private static func subtitle(
        sourceBundleIdentifier: String?,
        lastCopiedAt: Date,
        numberOfCopies: Int,
        byteCount: Int
    ) -> String {
        var parts: [String] = []
        if let sourceBundleIdentifier, !sourceBundleIdentifier.isEmpty {
            parts.append(sourceBundleIdentifier)
        }
        parts.append(lastCopiedAt.formatted(date: .omitted, time: .shortened))
        if numberOfCopies > 1 {
            parts.append("\(numberOfCopies)x")
        }
        if byteCount > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file))
        }
        return parts.joined(separator: " - ")
    }
}

struct ClipboardPasteboardCapture: Sendable {
    let contents: [ClipboardHistoryContent]
    let sourceBundleIdentifier: String?
    let capturedAt: Date
    let derivedText: String?

    init(
        contents: [ClipboardHistoryContent],
        sourceBundleIdentifier: String?,
        capturedAt: Date,
        derivedText: String? = nil
    ) {
        self.contents = contents
        self.sourceBundleIdentifier = sourceBundleIdentifier
        self.capturedAt = capturedAt
        self.derivedText = derivedText
    }
}

struct ClipboardPasteboardCaptureConfiguration: Sendable {
    let maxItemBytes: Int
    let sourceBundleIdentifier: String?
    let capturedAt: Date
    let ignoredTypes: Set<String>

    init(
        maxItemBytes: Int,
        sourceBundleIdentifier: String?,
        capturedAt: Date,
        ignoredTypes: Set<String> = []
    ) {
        self.maxItemBytes = maxItemBytes
        self.sourceBundleIdentifier = sourceBundleIdentifier
        self.capturedAt = capturedAt
        self.ignoredTypes = ignoredTypes
    }
}
