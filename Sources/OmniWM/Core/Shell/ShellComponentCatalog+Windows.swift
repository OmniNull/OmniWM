// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import TOML

struct ShellAppWindowDeclaration: Equatable, Sendable {
    let view: String
    let contentSize: CGSize
    let minimumContentSize: CGSize
    let children: [String: ShellAppChildDefinition]
}

extension ShellComponentCatalog {
    static func window(_ node: TOMLNode?, widget: String, views: [String]) throws -> ShellAppWindowDeclaration? {
        guard let node else { return nil }
        let place = "\(widget) [window]"
        guard case let .table(table) = node else { throw Failure("\(place) must be a table") }
        try checkKeys(table, allowed: ["view", "width", "height", "minWidth", "minHeight", "children"], place: place)
        let view = try windowView(table["view"], fallback: "window", views: views, place: place)
        let sizes = try windowSizes(table, place: place)
        return ShellAppWindowDeclaration(
            view: view, contentSize: sizes.preferred, minimumContentSize: sizes.minimum,
            children: try windowChildren(table["children"], widget: widget, views: views)
        )
    }

    private static func windowChildren(
        _ node: TOMLNode?, widget: String, views: [String]
    ) throws -> [String: ShellAppChildDefinition] {
        guard let node else { return [:] }
        let place = "\(widget) [window.children]"
        guard case let .table(children) = node else { throw Failure("\(place) must be a table") }
        var result: [String: ShellAppChildDefinition] = [:]
        for id in children.keys.sorted() {
            let place = "\(widget) [window.children.\(id)]"
            guard validName(id) else { throw Failure("\(place): invalid child id") }
            guard case let .table(table)? = children[id] else { throw Failure("\(place) must be a table") }
            try checkKeys(
                table, allowed: ["kind", "view", "title", "width", "height", "minWidth", "minHeight"], place: place
            )
            guard case let .string(rawKind)? = table["kind"], let kind = ShellAppChildDefinition.Kind(rawValue: rawKind)
            else { throw Failure("\(place) kind must be sheet or utility") }
            let view = try windowView(table["view"], fallback: "", views: views, place: place)
            guard case let .string(title)? = table["title"],
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw Failure("\(place) title must be a nonempty string") }
            let sizes = try windowSizes(table, place: place)
            result[id] = ShellAppChildDefinition(
                id: id, view: view, title: title, kind: kind,
                contentSize: sizes.preferred, minimumContentSize: sizes.minimum
            )
        }
        return result
    }

    private static func windowView(
        _ node: TOMLNode?, fallback: String, views: [String], place: String
    ) throws -> String {
        let view = try string(node, fallback: fallback, place: "\(place) view")
        guard validName(view), views.contains(view) else {
            throw Failure("\(place) view must name a declared component view: \(view)")
        }
        return view
    }

    private static func windowSizes(
        _ table: [String: TOMLNode], place: String
    ) throws -> (preferred: CGSize, minimum: CGSize) {
        func points(_ key: String) throws -> CGFloat {
            guard let value = ShellConfig.number(table[key]), value.isFinite, value > 0 else {
                throw Failure("\(place) \(key) must be positive finite points")
            }
            return CGFloat(value)
        }
        let preferred = try CGSize(width: points("width"), height: points("height"))
        let minimum = try CGSize(width: points("minWidth"), height: points("minHeight"))
        guard preferred.width >= minimum.width, preferred.height >= minimum.height else {
            throw Failure("\(place) width and height must meet minWidth and minHeight")
        }
        return (preferred, minimum)
    }
}
