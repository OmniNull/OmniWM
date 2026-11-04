// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import TOML

extension ShellComponentCatalog {
    static func load(
        _ widget: String, folder: URL, sourceFile: String = "component.luau"
    ) throws -> ShellComponentDescriptor {
        guard validName(widget) else { throw Failure("Invalid component name \(widget)") }
        let url = folder.appendingPathComponent("component.toml")
        let data = try SettingsFileAccess.readContents(at: url).data
        guard data.count <= 256 * 1024 else { throw Failure("\(widget)/component.toml is larger than 256 KiB") }
        let table = try TOMLDecoder().decode([String: TOMLNode].self, from: data)
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(sourceFile).path) else {
            throw Failure("\(widget) has no \(sourceFile)")
        }
        try checkKeys(
            table,
            allowed: ["title", "icon", "views", "uses", "options", "capabilities", "provider", "window"],
            place: widget
        )
        let title = try string(table["title"], fallback: widget, place: "\(widget) title")
        let icon = try string(table["icon"], fallback: "square.grid.2x2", place: "\(widget) icon")
        let views = try strings(table["views"], fallback: [], place: "\(widget) views")
        guard !views.isEmpty, views.allSatisfy(validName), Set(views).count == views.count else {
            throw Failure("\(widget) views must contain unique view names")
        }
        let uses = try strings(table["uses"], fallback: [], place: "\(widget) uses")
        guard uses.allSatisfy(validName), Set(uses).count == uses.count else {
            throw Failure("\(widget) uses must contain unique component names")
        }
        let options = try parseOptions(table["options"], place: widget)
        let capabilities = try parseCapabilities(table["capabilities"], place: widget, describesPurpose: true)
        var command: [String]?
        if let node = table["provider"] {
            guard case let .table(provider) = node else { throw Failure("\(widget) provider must be a table") }
            try checkKeys(provider, allowed: ["command"], place: "\(widget) provider")
            let argv = try strings(provider["command"], fallback: [], place: "\(widget) provider command")
            guard let executable = argv.first, !executable.isEmpty, argv.count <= 64,
                  !executable.hasPrefix("/"), !executable.split(separator: "/").contains("..")
            else { throw Failure("\(widget) provider command must name a program inside its package") }
            command = argv
        }
        return ShellComponentDescriptor(
            widget: widget,
            title: title,
            icon: icon,
            views: views,
            uses: uses,
            options: options,
            capabilities: capabilities,
            providerCommand: command,
            folder: folder,
            window: try window(table["window"], widget: widget, views: views)
        )
    }
}
