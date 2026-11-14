// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension ShellWallpaperPalette {
    static func storeIndex(from data: Data) throws -> [String: Any] {
        guard let index = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        return index
    }

    static func desktopChoice(
        in index: [String: Any],
        location: (display: String, space: String),
        aerials: URL
    ) -> DesktopChoice? {
        guard let content = desktopContent(in: index, location: location) else { return nil }
        if let path = stillImagePath(of: content) {
            return .file(URL(fileURLWithPath: path))
        }
        guard let choices = content["Choices"] as? [[String: Any]], choices.count == 1 else { return .other }
        if content["Shuffle"] as? String != "$null" {
            return .shuffle
        }
        guard choices[0]["Provider"] as? String == aerialProvider,
              let data = choices[0]["Configuration"] as? Data,
              let configuration = try? PropertyListSerialization.propertyList(from: data, format: nil)
              as? [String: Any],
              let asset = configuration["assetID"] as? String,
              !asset.isEmpty, !asset.contains("/")
        else { return .other }
        let thumbnail = aerials.appendingPathComponent("thumbnails/\(asset).png").standardizedFileURL
        return .aerial(
            asset: asset,
            thumbnail: FileManager.default.fileExists(atPath: thumbnail.path) ? thumbnail : nil
        )
    }
}
