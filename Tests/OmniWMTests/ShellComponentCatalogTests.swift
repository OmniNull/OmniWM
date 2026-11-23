// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
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
        return {
            title = "World clock",
            views = { "compact", "expanded" },
            options = {
                zone = { type = "string", default = "Europe/London", maxLength = 64 },
                seconds = { type = "boolean", default = false },
                size = { type = "number", default = 12, min = 8, max = 40, step = 2 },
                face = { type = "choice", choices = { "digital", "analog" }, default = "digital" },
                labels = { type = "strings", default = { "Home" }, maxLength = 20 },
            },
        }
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
        let cases = [
            ("type = \"number\", default = 4, min = 8", "broken option value: invalid default"),
            ("type = \"number\", step = 0", "broken option value: invalid step"),
            ("type = \"number\", min = 3, max = 1", "broken option value: min is greater than max"),
            ("type = \"choice\"", "broken option value needs choices"),
            ("type = \"boolean\", default = \"yes\"", "broken option value: invalid default"),
            ("type = \"string\", maxLength = -1", "broken option value: invalid maxLength")
        ]
        for (option, expectedReason) in cases {
            try component("broken", manifest: "return { views = { 'compact' }, options = { value = { \(option) } } }")
            XCTAssertThrowsError(try ShellComponentCatalog.load("broken", directories: [root])) { error in
                XCTAssertEqual(error.localizedDescription, expectedReason)
            }
        }
        for key in ShellComponentCatalog.reservedOptions {
            try component(
                "broken",
                manifest: "return { views = { \"compact\" }, options = { [\"\(key)\"] = { type = \"boolean\" } } }"
            )
            XCTAssertThrowsError(try ShellComponentCatalog.load("broken", directories: [root])) { error in
                XCTAssertEqual(error.localizedDescription, "broken: reserved or invalid option name \(key)")
            }
        }
    }

    func testUsesResolveTransitivelyOnceAndLayerOverrideWins() throws {
        let fallback = root.appendingPathComponent("profile")
        try component("base", manifest: "return { title = \"User base\", views = { \"compact\" } }")
        try component("custom", manifest: "return { views = { \"compact\" }, uses = { \"base\" } }", layer: fallback)
        try component("base", manifest: "return { title = \"Stock base\", views = { \"compact\" } }", layer: fallback)
        let result = try ShellComponentCatalog.resolve([
            ShellComponentInstance(id: "one", widget: "custom"),
            ShellComponentInstance(id: "two", widget: "custom")
        ], directories: [root, fallback])
        XCTAssertEqual(result.descriptors.map(\.widget), ["base", "custom"])
        XCTAssertEqual(result.descriptors.first?.title, "User base")
        XCTAssertEqual(result.instances.map(\.id), ["one", "two"])
        try component("base", manifest: "return { views = { \"compact\" }, uses = { \"custom\" } }")
        XCTAssertThrowsError(try ShellComponentCatalog.resolve(
            result.instances,
            directories: [root, fallback]
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("cycle"))
        }
    }

    func testProviderInstanceKeyUsesOrdinaryOptionValidationAndDoesNotGrantTrust() throws {
        let table = try ShellLiteralMetadata.read(
            Data("return { components = { { id = \"one\", widget = \"clock\", provider = true } } }".utf8),
            filename: "shell.luau"
        )
        let instance = try XCTUnwrap(ShellComponentCatalog.instances(in: table["components"]).first)
        XCTAssertEqual(instance.options["provider"], .bool(true))
        try component("clock", manifest: "return { views = { \"compact\" } }")
        let undeclared = try ShellComponentCatalog.load("clock", directories: [root])
        XCTAssertThrowsError(try undeclared.validate(instance))
        try component(
            "clock",
            manifest: "return { views = { \"compact\" }, options = { provider = { type = \"boolean\" } } }"
        )
        let declared = try ShellComponentCatalog.load("clock", directories: [root])
        XCTAssertEqual(try declared.validate(instance).options["provider"], .bool(true))
        XCTAssertFalse(declared.authorizesProvider(instance))
    }

    func testInstancesRejectDuplicateIdsTraversalAndUnsupportedValues() throws {
        for text in [
            "return { components = { { id = \"same\", widget = \"clock\" }, { id = \"same\", widget = \"clock\" } } }",
            "return { components = { { id = \"a\", widget = \"../clock\" } } }",
            "return { components = { { id = \"a\", widget = \"clock\", enabled = 1 } } }",
            "return { components = { { id = \"a\", widget = \"clock\", zone = { nested = \"value\" } } } }",
            "return { components = { { id = \"a\", widget = \"clock\", commands = { \"session\" } } } }"
        ] {
            let table = try ShellLiteralMetadata.read(Data(text.utf8), filename: "shell.luau")
            XCTAssertThrowsError(try ShellComponentCatalog.instances(in: table["components"]))
        }
    }

    func testInstanceProviderCapabilityIsRejectedWhileTheManifestCanDeclareIt() throws {
        let table = try ShellLiteralMetadata.read(Data("""
        return {
            components = { { id = "a", widget = "clock", capabilities = { provider = true } } },
        }
        """.utf8), filename: "shell.luau")
        XCTAssertThrowsError(try ShellComponentCatalog.instances(in: table["components"])) { error in
            XCTAssertTrue(error.localizedDescription.contains("provider"))
        }
        try component("clock", manifest: "return { views = { \"compact\" }, capabilities = { provider = true } }")
        let descriptor = try ShellComponentCatalog.load("clock", directories: [root])
        XCTAssertTrue(descriptor.capabilities.provider)
    }

    private func component(_ name: String, manifest: String, layer: URL? = nil) throws {
        let folder = (layer ?? root).appendingPathComponent("widgets/\(name)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(manifest.utf8).write(to: folder.appendingPathComponent("component.manifest.luau"))
        try Data("return { views = {} }".utf8).write(to: folder.appendingPathComponent("component.luau"))
    }
}
