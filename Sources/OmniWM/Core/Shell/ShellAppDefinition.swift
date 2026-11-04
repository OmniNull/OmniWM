// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

struct ShellAppDefinition: Equatable, Sendable {
    let id: String
    let title: String
    let contentSize: CGSize
    let minimumContentSize: CGSize
    let folder: URL
    var view = "window"
    var component: ShellComponentDescriptor?
    var icon = "app"
    var children: [String: ShellAppChildDefinition] = [:]

    static var example: Self? {
        example(in: .module)
    }

    static func example(in bundle: Bundle) -> Self? {
        guard let entry = bundle.url(forResource: "init", withExtension: "luau", subdirectory: "ShellApps/example")
        else { return nil }
        return try? load(id: ShellAppWindowManager.exampleID, folder: entry.deletingLastPathComponent())
    }

    static func load(id: String, folder: URL) throws -> Self {
        let component = try ShellComponentCatalog.load(id, folder: folder, sourceFile: "init.luau")
        guard let window = component.window else {
            throw ShellComponentCatalog.Failure("\(id)/component.toml: missing [window]")
        }
        return Self(
            id: id, title: component.title, contentSize: window.contentSize,
            minimumContentSize: window.minimumContentSize, folder: folder,
            view: window.view, component: component, icon: component.icon, children: window.children
        )
    }
}

struct ShellAppChildDefinition: Equatable, Sendable {
    enum Kind: String, Sendable {
        case sheet
        case utility
    }

    let id: String
    let view: String
    let title: String
    var kind = Kind.sheet
    let contentSize: CGSize
    let minimumContentSize: CGSize
}
