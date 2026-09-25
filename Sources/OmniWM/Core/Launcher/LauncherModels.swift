// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

enum LauncherViewStyle: String, Codable, Sendable {
    case grid
    case list
}

enum LauncherSectionID: Hashable, Sendable {
    case suggestions
    case recents
    case results
    case all
    case other
    case category(String)
}

struct LauncherSection<Item: Identifiable & Sendable>: Identifiable, Sendable where Item.ID: Sendable {
    let id: LauncherSectionID
    let title: String
    let items: [Item]
}

enum LauncherChipFilter: Hashable, Sendable {
    case applicationCategory(String)
    case filePredicate(String)
}

struct LauncherChip: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let filter: LauncherChipFilter
}

struct LauncherSelection: Hashable, Sendable {
    let sectionID: LauncherSectionID
    let itemID: String
}

struct LauncherApplicationResult: Identifiable, Sendable {
    let id: String
    let bundleURL: URL
    let bundleIdentifier: String?
    let displayName: String
    let categoryName: String?
    let recordSequence: UInt64

    init(
        bundleURL: URL,
        bundleIdentifier: String?,
        displayName: String,
        categoryName: String? = nil,
        recordSequence: UInt64 = 0
    ) {
        id = bundleURL.path
        self.bundleURL = bundleURL
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.categoryName = categoryName
        self.recordSequence = recordSequence
    }
}

struct LauncherFileResult: Identifiable, Sendable {
    let id: String
    let fileURL: URL
    let displayName: String
    let contentTypeIdentifier: String?
    let kind: String?
    let isDirectory: Bool
    let size: Int64?
    let createdAt: Date?
    let modifiedAt: Date?
    let lastOpenedAt: Date?

    init(
        fileURL: URL,
        displayName: String,
        contentTypeIdentifier: String? = nil,
        kind: String? = nil,
        isDirectory: Bool = false,
        size: Int64? = nil,
        createdAt: Date? = nil,
        modifiedAt: Date? = nil,
        lastOpenedAt: Date? = nil
    ) {
        id = fileURL.path
        self.fileURL = fileURL
        self.displayName = displayName
        self.contentTypeIdentifier = contentTypeIdentifier
        self.kind = kind
        self.isDirectory = isDirectory
        self.size = size
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.lastOpenedAt = lastOpenedAt
    }
}
