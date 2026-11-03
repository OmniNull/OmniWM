// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

struct ShellAppDefinition: Sendable {
    let id: String
    let title: String
    let contentSize: CGSize
    let minimumContentSize: CGSize
    let folder: URL
    var icon = "app"
    var children: [String: ShellAppChildDefinition] = [:]

    static var example: Self? {
        example(in: .module)
    }

    static func example(in bundle: Bundle) -> Self? {
        guard let entry = bundle.url(forResource: "init", withExtension: "luau", subdirectory: "ShellApps/example")
        else { return nil }
        return Self(
            id: ShellAppWindowManager.exampleID, title: "OmniShell Example",
            contentSize: CGSize(width: 640, height: 420), minimumContentSize: CGSize(width: 280, height: 240),
            folder: entry.deletingLastPathComponent(),
            children: ["confirm": ShellAppChildDefinition(
                id: "confirm", view: "confirm", title: "Confirm deletion",
                contentSize: CGSize(width: 360, height: 200), minimumContentSize: CGSize(width: 280, height: 160)
            )]
        )
    }

    func source() throws -> ShellWidgetSource {
        let component = try String(contentsOf: folder.appendingPathComponent("init.luau"), encoding: .utf8)
        var source = ShellWidgetSource(
            chunk: "@widgets/\(id)/init.luau",
            main: """
            function window(ctx)
                return ui.component{ id = "app", view = ctx.view.name, w = ctx.view.w, h = ctx.view.h }
            end
            """,
            modules: [.init(path: "widgets/\(id)/component.luau", source: component)]
        )
        source.components = [.init(id: "app", widget: id)]
        source.componentDescriptors = [.init(
            widget: id, title: title, icon: icon, views: ["window"] + children.values.map(\.view).sorted(), uses: [],
            options: [:],
            capabilities: ShellComponentCapabilities(), providerCommand: nil, folder: folder
        )]
        source.assetPackages = [id: folder]
        source.profile = "app.\(id)"
        source.principal = ShellWidgetPrincipal(role: .root, name: source.profile, folder: folder)
        return source
    }
}

struct ShellAppChildDefinition: Sendable {
    let id: String
    let view: String
    let title: String
    let contentSize: CGSize
    let minimumContentSize: CGSize
}
