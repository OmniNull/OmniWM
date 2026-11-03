// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

struct ShellAppAuthoringFixture {
    let config: URL
    let id: String
    let title = "Local app fixture"
    let preferred = CGSize(width: 480, height: 320)
    let minimum = CGSize(width: 240, height: 160)
    let childPreferred = CGSize(width: 360, height: 240)
    let childMinimum = CGSize(width: 180, height: 120)
    let view: String

    init(config: URL? = nil, id: String = "local-app", view: String = "main") {
        self.config = (config ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
            .resolvingSymlinksInPath().standardizedFileURL
        self.id = id
        self.view = view
    }

    var directory: URL {
        config.appendingPathComponent("apps", isDirectory: true)
    }

    var folder: URL {
        directory.appendingPathComponent(id, isDirectory: true)
    }

    var manifest: String {
        """
        title = "\(title)"
        icon = "square.and.pencil"
        views = ["\(view)", "confirm", "preferences"]
        [window]
        view = "\(view)"
        width = \(preferred.width)
        height = \(preferred.height)
        minWidth = \(minimum.width)
        minHeight = \(minimum.height)
        [window.children.confirm]
        kind = "sheet"
        view = "confirm"
        title = "Confirm fixture"
        width = \(childPreferred.width)
        height = \(childPreferred.height)
        minWidth = \(childMinimum.width)
        minHeight = \(childMinimum.height)
        [window.children.preferences]
        kind = "utility"
        view = "preferences"
        title = "Preferences fixture"
        width = \(childPreferred.width)
        height = \(childPreferred.height)
        minWidth = \(childMinimum.width)
        minHeight = \(childMinimum.height)
        """
    }

    var source: String {
        """
        local label = require('@self/lib/label')
        return {views={
            ["\(view)"] = function(ctx) return ui.text{text=label} end,
            confirm = function(ctx) return ui.text{text='Confirm fixture'} end,
            preferences = function(ctx) return ui.text{text='Preferences fixture'} end,
        }}
        """
    }

    func write(manifest: String? = nil, source: String? = nil) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try writeFile(manifest ?? self.manifest, path: "component.toml")
        try writeFile(source ?? self.source, path: "init.luau")
        try writeFile("return 'Local module fixture'", path: "lib/label.luau")
    }

    func writeFile(_ content: String, path: String) throws {
        let file = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: file)
    }

    func remove() throws {
        if FileManager.default.fileExists(atPath: config.path) { try FileManager.default.removeItem(at: config) }
    }
}
