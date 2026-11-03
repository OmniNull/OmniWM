// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension ShellAppDefinition {
    func source(validatingViews: Bool = false) throws -> ShellWidgetSource {
        let descriptor = component ?? ShellComponentDescriptor(
            widget: id, title: title, icon: icon, views: [view] + children.values.map(\.view).sorted(),
            uses: [], options: [:], capabilities: ShellComponentCapabilities(), providerCommand: nil, folder: folder
        )
        let dependencies = try ShellComponentCatalog.resolve(
            descriptor.uses.map { ShellComponentInstance(id: $0, widget: $0) },
            directories: [folder] + [ShellDefaults.bundled].compactMap { $0 }
        ).descriptors
        guard !dependencies.contains(where: { $0.widget == id }) else {
            throw ShellComponentCatalog.Failure("\(id): component dependency collides with the app id")
        }
        let descriptors = dependencies + [descriptor]
        let modules = try descriptors.flatMap { descriptor in
            try Self.modules(descriptor, isApp: descriptor.widget == id)
        }
        guard modules.count <= ShellComponentCatalog.rootModuleLimit else {
            throw ShellComponentCatalog.Failure("\(id): app modules exceed \(ShellComponentCatalog.rootModuleLimit)")
        }
        var source = ShellWidgetSource(
            chunk: "@widgets/\(id)/init.luau",
            main: (validatingViews ? validation(descriptor) : "") + """
            function window(ctx)
                return ui.component{ id = "app", view = ctx.view.name, w = ctx.view.w, h = ctx.view.h }
            end
            """,
            modules: modules
        )
        source.moduleLimit = ShellComponentCatalog.rootModuleLimit
        source.components = [try descriptor.validate(.init(id: "app", widget: id))]
        source.componentDescriptors = descriptors
        source.assetPackages = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.widget, $0.folder) })
        source.fontFolders = ShellFontLibrary.folders([folder])
        source.strings = try ShellStrings.load([folder])
        source.profile = "app.\(id)"
        source.principal = ShellWidgetPrincipal(role: .root, name: source.profile, folder: folder)
        return source
    }

    private static func modules(
        _ descriptor: ShellComponentDescriptor,
        isApp: Bool
    ) throws -> [ShellWidgetSource.Module] {
        let prefix = descriptor.folder.standardizedFileURL.path + "/"
        var paths: Set<String> = []
        return try ShellWidgetSourceLoader.entries(in: descriptor.folder, directories: false)
            .sorted { $0.path < $1.path }
            .map { file in
                var relative = String(file.standardizedFileURL.path.dropFirst(prefix.count))
                if isApp, relative == "init.luau" { relative = "component.luau" }
                let path = "widgets/\(descriptor.widget)/\(relative)"
                guard paths.insert(path).inserted else {
                    throw ShellComponentCatalog.Failure("\(descriptor.widget): duplicate module \(relative)")
                }
                return ShellWidgetSource.Module(path: path, source: try ShellWidgetSourceLoader.read(file))
            }
    }

    private func validation(_ descriptor: ShellComponentDescriptor) -> String {
        let module = Self.luauString("@self/component")
        let checks = descriptor.views.map { view in
            let message = Self.luauString("\(id)/component.toml: missing declared view \(view)")
            return "assert(type(rawget(views, \(Self.luauString(view)))) == 'function', \(message))"
        }.joined(separator: "\n")
        return """
        local definition = require(\(module))
        assert(type(definition) == 'table', \(Self.luauString("\(id): component must return a table")))
        local views = rawget(definition, 'views')
        assert(type(views) == 'table', \(Self.luauString("\(id): component must return a views table")))
        \(checks)

        """
    }

    private static func luauString(_ value: String) -> String {
        "\"" + value.utf8.map { "\\\($0)" }.joined() + "\""
    }
}
