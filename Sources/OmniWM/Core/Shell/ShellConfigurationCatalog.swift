// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

struct ShellConfigurationCatalog: Equatable, Sendable {
    let directories: [URL]
    let root: String
    let entries: [ShellComponentCatalog.Entry]
    let settings: ShellRootSettings?
    let bytes: [UInt8]
    let schema: [UInt8]

    var descriptors: [String: ShellComponentDescriptor] {
        Dictionary(uniqueKeysWithValues: entries.compactMap { entry in
            entry.descriptor.map { (entry.widget, $0) }
        })
    }
}

actor ShellConfigurationCatalogLoader {
    let queue = DispatchSerialQueue(label: "com.barut.OmniWM.shell.catalog", qos: .utility)
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    func load(directories: [URL], root: String) throws -> ShellConfigurationCatalog {
        let entries = try ShellComponentCatalog.installed(directories: directories)
        let settings = try ShellRootSettings.load(root, directories: directories)
        return try ShellConfigurationCatalog(
            directories: directories, root: root, entries: entries, settings: settings,
            bytes: ShellComponentCatalog.catalogBytes(entries),
            schema: ShellComponentCatalog.settingsBytes(settings?.options ?? [:])
        )
    }

    func settings(widgets: [String], directories: [URL]) throws -> [String: ShellRootSettings] {
        var result: [String: ShellRootSettings] = [:]
        for widget in Set(widgets) {
            let source = directories.first {
                FileManager.default.fileExists(atPath: $0.appendingPathComponent("widgets/\(widget)/init.luau").path)
            }
            if let source { result[widget] = try ShellRootSettings.load(widget, directories: [source]) }
        }
        return result
    }
}
