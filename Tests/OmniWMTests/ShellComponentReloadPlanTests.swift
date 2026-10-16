// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import XCTest

final class ShellComponentReloadPlanTests: XCTestCase {
    func testEditedComponentIncludesTransitiveDependentsWithoutUnrelatedWidgets() throws {
        let modules = [module("media"), module("custom"), module("second"), module("clock")]
        let descriptors = [
            descriptor("media"),
            descriptor("custom", uses: ["media"]),
            descriptor("second", uses: ["custom"]),
            descriptor("clock")
        ]
        let result = try XCTUnwrap(plan(modules, previous: modules, descriptors: descriptors) {
            !$0.path.contains("/media/")
        })
        XCTAssertEqual(result.widgets, ["custom", "media", "second"])
        XCTAssertEqual(result.modules.map(\.path), [modules[0].path])
    }

    func testRemovedSourceAndNewTypeAreOneDeterministicBatch() throws {
        let old = [module("media"), module("media", file: "helper"), module("clock")]
        let next = [old[0], old[2], module("jobs")]
        let result = try XCTUnwrap(plan(next, previous: old) { _ in true })
        XCTAssertEqual(result.widgets, ["jobs", "media"])
        XCTAssertEqual(result.modules.map(\.path), [next[2].path, old[1].path])
        XCTAssertEqual(result.modules.first?.source, "return {}")
        XCTAssertNil(result.modules.last?.source)
    }

    func testRootAndSharedLibraryEditsRequireFullReload() {
        let helper = ShellWidgetSource.Module(path: "look/widgets/lake/helper.luau", source: "return {}")
        let library = ShellWidgetSource.Module(path: "look/lib/lake/view.luau", source: "return {}")
        for changed in [helper, library] {
            XCTAssertNil(plan([changed], previous: [changed]) { _ in false })
            XCTAssertNil(plan([], previous: [changed]) { _ in true })
        }
        var source = source([module("media")])
        source = ShellWidgetSource(
            chunk: source.chunk,
            main: "function render() return nil end",
            modules: source.modules
        )
        XCTAssertNil(ShellComponentReloadPlan.make(
            source: source, loaded: .init(chunk: source.chunk, main: "old root", modules: []), previousDescriptors: [],
            matches: { _ in true }
        ))
    }

    func testChangedUsesRetiresCachedDefinitionAndItsOldDependents() throws {
        let modules = [module("media"), module("custom"), module("second")]
        let previous = [
            descriptor("media"),
            descriptor("custom", uses: ["media"]),
            descriptor("second", uses: ["custom"])
        ]
        let next = [descriptor("media"), descriptor("custom"), descriptor("second")]
        var source = source(modules)
        source.componentDescriptors = next
        let result = try XCTUnwrap(ShellComponentReloadPlan.make(
            source: source, loaded: .init(chunk: source.chunk, main: source.main, modules: Set(modules.map(\.path))),
            previousDescriptors: previous, matches: { _ in true }
        ))
        XCTAssertEqual(result.widgets, ["custom", "second"])
        XCTAssertTrue(result.modules.isEmpty)
    }

    func testMetadataAndUsesOrderDoNotResetComponentState() throws {
        let modules = [module("custom")]
        var source = source(modules)
        source.componentDescriptors = [descriptor("custom", uses: ["b", "a"], title: "New title")]
        let result = try XCTUnwrap(ShellComponentReloadPlan.make(
            source: source, loaded: .init(chunk: source.chunk, main: source.main, modules: Set(modules.map(\.path))),
            previousDescriptors: [descriptor(
                "custom",
                uses: ["a", "b"]
            )], matches: { _ in true }
        ))
        XCTAssertTrue(result.widgets.isEmpty)
        XCTAssertTrue(result.modules.isEmpty)
    }

    private func plan(
        _ modules: [ShellWidgetSource.Module],
        previous: [ShellWidgetSource.Module],
        descriptors: [ShellComponentDescriptor] = [],
        matches: (ShellWidgetSource.Module) -> Bool
    ) -> ShellComponentReloadPlan? {
        var source = source(modules)
        source.componentDescriptors = descriptors
        return ShellComponentReloadPlan.make(
            source: source, loaded: .init(chunk: source.chunk, main: source.main, modules: Set(previous.map(\.path))),
            previousDescriptors: descriptors, matches: matches
        )
    }

    private func source(_ modules: [ShellWidgetSource.Module]) -> ShellWidgetSource {
        ShellWidgetSource(
            chunk: "@look/widgets/lake/init.luau",
            main: "function render() return ui.box{} end",
            modules: modules
        )
    }

    private func module(_ widget: String, file: String = "component") -> ShellWidgetSource.Module {
        ShellWidgetSource.Module(path: "look/widgets/\(widget)/\(file).luau", source: "return {}")
    }

    private func descriptor(_ widget: String, uses: [String] = [], title: String? = nil) -> ShellComponentDescriptor {
        ShellComponentDescriptor(
            widget: widget, title: title ?? widget, icon: "square", views: ["compact"], uses: uses,
            options: [:], capabilities: .init(), providerCommand: nil,
            folder: URL(fileURLWithPath: "/unused/\(widget)")
        )
    }
}
