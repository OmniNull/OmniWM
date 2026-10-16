// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMScriptHost
import XCTest

final class ShellComponentListingTests: XCTestCase {
    func testCatalogListsAllLayersMarksOverridesAndKeepsBrokenEntryVisible() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let own = root.appendingPathComponent("own")
        let profile = root.appendingPathComponent("profile")
        let fallback = root.appendingPathComponent("default")
        try component("clock", title: "User clock", layer: own)
        try component("clock", title: "Profile clock", layer: profile)
        try component("clock", title: "Built-in clock", layer: fallback)
        try component("media", title: "Music", layer: fallback)
        try component("broken", title: "Broken", layer: own, source: false)
        let entries = try ShellComponentCatalog.installed(directories: [own, profile, fallback])
        XCTAssertEqual(entries.map(\.widget), ["broken", "clock", "media"])
        XCTAssertNil(entries[0].descriptor)
        XCTAssertTrue(entries[0].error?.contains("component.luau") == true)
        XCTAssertEqual(entries[1].descriptor?.title, "User clock")
        XCTAssertEqual(
            entries[1].sources.map { $0.resolvingSymlinksInPath() },
            [own, profile, fallback].map { $0.appendingPathComponent("widgets/clock").resolvingSymlinksInPath() }
        )
        XCTAssertEqual(entries[2].descriptor?.title, "Music")
    }

    func testAggregateCatalogLimitRejectsUnusedOversizedMetadata() throws {
        let folder = FileManager.default.temporaryDirectory
        let entries = (0 ..< 20).map { index in
            ShellComponentCatalog.Entry(
                widget: "widget-\(index)",
                sources: [folder],
                descriptor: nil,
                error: String(repeating: "x", count: 250 * 1024)
            )
        }
        XCTAssertThrowsError(try ShellComponentCatalog.catalogBytes(entries))
        XCTAssertLessThan(
            try ShellComponentCatalog.catalogBytes(Array(entries.prefix(2))).count,
            ShellComponentCatalog.metadataByteLimit
        )
    }

    func testRootSettingsReuseOptionSchemaAndRejectPrivileges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("widgets/lake")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("settings.toml")
        let manifest = """
        [options.width]
        type = "number"
        min = 200
        max = 600
        step = 20
        default = 400
        [options.hover]
        type = "boolean"
        default = true
        [options.motion]
        type = "choice"
        choices = ["smooth", "spring"]
        default = "spring"
        """
        try Data(manifest.utf8).write(to: file)
        let schema = try XCTUnwrap(ShellRootSettings.load("lake", directories: [root]))
        XCTAssertEqual(
            try schema.values(applying: ["width": .number(420)]),
            ["width": .number(420), "hover": .bool(true), "motion": .string("spring")]
        )
        XCTAssertThrowsError(try schema.values(applying: ["width": .number(410)]))
        XCTAssertThrowsError(try schema.values(applying: ["unknown": .bool(true)]))
        let layout = ShellIslandLayout(profile: "lake", root: "lake", components: [])
        let edit = try layout.applying(
            .rootSetting(key: "width", value: .number(420)),
            catalog: [:],
            rootOptions: schema.options
        )
        XCTAssertEqual(edit.change, .rootSetting(key: "width", value: .number(420)))
        for key in ShellComponentCatalog.reservedOptions {
            XCTAssertThrowsError(try layout.applying(
                .rootSetting(key: key, value: .bool(true)),
                catalog: [:],
                rootOptions: schema.options
            ))
            try Data("[options.\(key)]\ntype = 'boolean'\n".utf8).write(to: file)
            if key == "network" {
                let settings = try XCTUnwrap(ShellRootSettings.load("lake", directories: [root]))
                XCTAssertEqual(try settings.values(applying: [key: .bool(true)]), [key: .bool(true)])
                XCTAssertThrowsError(try settings.values(applying: [key: .string("example.com")]))
                XCTAssertThrowsError(try ShellComponentCatalog.parseOptions(
                    .table([key: .table(["type": .string("boolean")])]), place: "component"
                ))
            } else {
                XCTAssertThrowsError(try ShellRootSettings.load("lake", directories: [root]))
            }
        }
        XCTAssertNil(try ShellRootSettings.load("other", directories: [root]))
    }

    func testCatalogWireExposesSchemaWithoutExecutingComponentSource() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("widgets/clock")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("error('must not execute')".utf8).write(to: folder.appendingPathComponent("component.luau"))
        try Data("""
        title = "Clock"
        views = ["compact", "expanded"]
        [options.zone]
        type = "choice"
        title = "Zone"
        default = "UTC"
        choices = ["UTC", "Asia/Tokyo"]
        [options.size]
        type = "number"
        min = 10
        max = 30
        step = 2
        default = 20
        """.utf8).write(to: folder.appendingPathComponent("component.toml"))
        let entries = try ShellComponentCatalog.installed(directories: [root])
        let vm = try XCTUnwrap(omni_vm_create(32 << 20, "catalog", 7))
        defer { _ = omni_vm_destroy(vm) }
        let source = """
        function render(ctx)
            local entry = ctx.data.catalog[1]
            assert(entry.widget == "clock" and entry.title == "Clock")
            assert(#entry.views == 2 and #entry.overrides == 0)
            assert(entry.options.zone.type == "choice" and entry.options.zone.default == "UTC")
            assert(entry.options.zone.choices[2] == "Asia/Tokyo")
            assert(entry.options.size.min == 10 and entry.options.size.max == 30 and entry.options.size.step == 2)
            assert(entry.error == nil)
            return ui.text { text = entry.title }
        end
        """
        var error = [CChar](repeating: 0, count: 512)
        XCTAssertEqual(
            omni_vm_load(vm, "@catalog-test", source, source.utf8.count, 100_000_000, &error, error.count),
            OMNI_OK
        )
        let instance = try XCTUnwrap(omni_instance_create(vm))
        defer { omni_instance_destroy(instance) }
        let bytes = try ShellComponentCatalog.catalogBytes(entries)
        XCTAssertEqual(
            bytes.withUnsafeBufferPointer { omni_instance_set_value(instance, "catalog", $0.baseAddress, $0.count) },
            OMNI_OK
        )
        var stats = omni_render_stats()
        let status = omni_instance_render(instance, OMNI_VIEW_BAR, 100_000_000, &stats, &error, error.count)
        XCTAssertEqual(status, OMNI_OK, error.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
    }

    private func component(_ name: String, title: String, layer: URL, source: Bool = true) throws {
        let folder = layer.appendingPathComponent("widgets/\(name)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("title = '\(title)'\nviews = ['compact']\n".utf8)
            .write(to: folder.appendingPathComponent("component.toml"))
        if source {
            try Data("error('catalog must not execute source')".utf8)
                .write(to: folder.appendingPathComponent("component.luau"))
        }
    }
}
