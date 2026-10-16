// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import TOML
import XCTest

final class ShellComponentCatalogTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testAllOptionTypesMergeDefaultsAndRejectInvalidValues() throws {
        try component("clock", manifest: """
        title = "World clock"
        views = ["compact", "expanded"]
        [options.zone]
        type = "string"
        default = "Europe/London"
        maxLength = 64
        [options.seconds]
        type = "boolean"
        default = false
        [options.size]
        type = "number"
        default = 12
        min = 8
        max = 40
        step = 2
        [options.face]
        type = "choice"
        choices = ["digital", "analog"]
        default = "digital"
        [options.labels]
        type = "strings"
        default = ["Home"]
        maxLength = 20
        """)
        let catalog = try ShellComponentCatalog.load("clock", directories: [root])
        let first = try catalog.validate(ShellComponentInstance(
            id: "tokyo",
            widget: "clock",
            options: ["zone": .string("Asia/Tokyo")]
        ))
        let second = try catalog.validate(ShellComponentInstance(id: "london", widget: "clock"))
        XCTAssertEqual(first.options["zone"], .string("Asia/Tokyo"))
        XCTAssertEqual(second.options["zone"], .string("Europe/London"))
        XCTAssertEqual(first.options["seconds"], .bool(false))
        XCTAssertEqual(first.options["size"], .number(12))
        XCTAssertEqual(first.options["labels"], .strings(["Home"]))
        for (key, value) in [
            ("seconds", ShellComponentValue.string("true")), ("size", .number(13)),
            ("size", .number(42)), ("size", .number(.infinity)), ("face", .string("other")),
            ("labels", .strings([String(repeating: "x", count: 21)])), ("missing", .bool(true))
        ] {
            XCTAssertThrowsError(try catalog.validate(ShellComponentInstance(
                id: "test",
                widget: "clock",
                options: [key: value]
            )))
        }
    }

    func testInvalidSchemasAndReservedOptionsFailWithReasons() throws {
        for option in [
            "type = \"number\"\ndefault = 4\nmin = 8", "type = \"number\"\nstep = 0",
            "type = \"number\"\nmin = 3\nmax = 1", "type = \"choice\"",
            "type = \"boolean\"\ndefault = \"yes\"", "type = \"string\"\nmaxLength = -1"
        ] {
            try component("broken", manifest: "views = [\"compact\"]\n[options.value]\n" + option)
            XCTAssertThrowsError(try ShellComponentCatalog.load("broken", directories: [root])) { error in
                XCTAssertTrue(error.localizedDescription.contains("broken"))
            }
        }
        for key in ShellComponentCatalog.reservedOptions {
            try component("broken", manifest: "views = [\"compact\"]\n[options.\(key)]\ntype = \"boolean\"")
            XCTAssertThrowsError(try ShellComponentCatalog.load("broken", directories: [root]))
        }
    }

    func testUsesResolveTransitivelyOnceAndLayerOverrideWins() throws {
        let fallback = root.appendingPathComponent("profile")
        try component("base", manifest: "title = \"User base\"\nviews = [\"compact\"]")
        try component("custom", manifest: "views = [\"compact\"]\nuses = [\"base\"]", layer: fallback)
        try component("base", manifest: "title = \"Stock base\"\nviews = [\"compact\"]", layer: fallback)
        let result = try ShellComponentCatalog.resolve([
            ShellComponentInstance(id: "one", widget: "custom"),
            ShellComponentInstance(id: "two", widget: "custom")
        ], directories: [root, fallback])
        XCTAssertEqual(result.descriptors.map(\.widget), ["base", "custom"])
        XCTAssertEqual(result.descriptors.first?.title, "User base")
        XCTAssertEqual(result.instances.map(\.id), ["one", "two"])
        try component("base", manifest: "views = [\"compact\"]\nuses = [\"custom\"]")
        XCTAssertThrowsError(try ShellComponentCatalog.resolve(
            result.instances,
            directories: [root, fallback]
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("cycle"))
        }
    }

    func testInstancesRejectDuplicateIdsTraversalAndUnsupportedValues() throws {
        for text in [
            "components = [{id = 'same', widget = 'clock'}, {id = 'same', widget = 'clock'}]",
            "components = [{id = 'a', widget = '../clock'}]",
            "components = [{id = 'a', widget = 'clock', enabled = 1}]",
            "components = [{id = 'a', widget = 'clock', zone = {nested = 'value'}}]",
            "components = [{id = 'a', widget = 'clock', commands = ['session']}]"
        ] {
            let table = try TOMLDecoder().decode([String: TOMLNode].self, from: Data(text.utf8))
            XCTAssertThrowsError(try ShellComponentCatalog.instances(from: table["components"]))
        }
    }

    private func component(_ name: String, manifest: String, layer: URL? = nil) throws {
        let folder = (layer ?? root).appendingPathComponent("widgets/\(name)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(manifest.utf8).write(to: folder.appendingPathComponent("component.toml"))
        try Data("return { views = {} }".utf8).write(to: folder.appendingPathComponent("component.luau"))
    }
}
