// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit

@MainActor
enum HiddenBarGlyphProjection {
    static func current(bundleIDs: [String], iconCache: HiddenBarIconCache) -> [HiddenBarGlyph] {
        var appsByBundleID: [String: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications {
            if let bundleID = app.bundleIdentifier, appsByBundleID[bundleID] == nil {
                appsByBundleID[bundleID] = app
            }
        }
        var glyphs: [HiddenBarGlyph] = []
        for bundleID in bundleIDs {
            guard let app = appsByBundleID[bundleID] else { continue }
            let name = app.localizedName ?? bundleID
            guard let resolved = iconCache.resolvedItems(for: bundleID) else {
                glyphs.append(
                    HiddenBarGlyph(
                        key: MenuBarItemKey(bundleID: bundleID, ordinal: 0),
                        name: name,
                        image: app.icon,
                        size: CGSize(width: 16, height: 16)
                    )
                )
                continue
            }
            guard !resolved.isEmpty else { continue }
            for item in resolved {
                if let icon = item.icon {
                    let size = CGSize(
                        width: CGFloat(icon.image.width) / icon.scale,
                        height: CGFloat(icon.image.height) / icon.scale
                    )
                    glyphs.append(HiddenBarGlyph(
                        key: item.key,
                        name: name,
                        image: NSImage(cgImage: icon.image, size: size),
                        size: size
                    ))
                } else {
                    glyphs.append(HiddenBarGlyph(
                        key: item.key,
                        name: name,
                        image: app.icon,
                        size: CGSize(width: 16, height: 16)
                    ))
                }
            }
        }
        return glyphs
    }
}
