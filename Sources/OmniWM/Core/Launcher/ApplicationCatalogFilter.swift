// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

enum ApplicationCatalogFilter {
    static let finderPath = "/System/Library/CoreServices/Finder.app"

    static func roots(home: String) -> [String] {
        [
            "/Applications",
            "/System/Applications",
            "/System/Volumes/Preboot/Cryptexes/App/System/Applications",
            "/AppleInternal/Applications",
            "/System/Library/CoreServices/Applications",
            home + "/Applications",
            "/Users/Shared"
        ]
    }

    static func isCatalogPath(_ path: String, home: String) -> Bool {
        guard path.hasSuffix(".app") else { return false }
        if path == finderPath { return true }
        let parent = (path as NSString).deletingLastPathComponent
        if parent == home + "/Downloads" { return true }
        let roots = roots(home: home)
        if roots.contains(parent) { return true }
        let grandparent = (parent as NSString).deletingLastPathComponent
        return roots.contains(grandparent) && !isBundleDirectory(parent)
    }

    static func scannedBundlePaths(home: String, fileManager: FileManager = .default) -> [String] {
        var paths: [String] = []
        for root in roots(home: home) {
            guard let entries = try? fileManager.contentsOfDirectory(atPath: root) else { continue }
            for entry in entries where !entry.hasPrefix(".") {
                let path = (root as NSString).appendingPathComponent(entry)
                if entry.hasSuffix(".app") {
                    paths.append(path)
                    continue
                }
                var isDirectory: ObjCBool = false
                guard !isBundleDirectory(path),
                      fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
                      isDirectory.boolValue,
                      let children = try? fileManager.contentsOfDirectory(atPath: path)
                else {
                    continue
                }
                paths += children.filter { $0.hasSuffix(".app") }.map { (path as NSString).appendingPathComponent($0) }
            }
        }
        return paths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
    }

    private static func isBundleDirectory(_ path: String) -> Bool {
        ["app", "appex", "bundle", "framework", "plugin", "xpc"].contains((path as NSString).pathExtension.lowercased())
    }
}
