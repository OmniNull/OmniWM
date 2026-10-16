// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMScriptHost
import XCTest

private extension ShellWidgetPackage {
    func componentPackageWidths(_ key: ShellBarKey) -> [Float] {
        guard let script, let instance = script.instances[key] else { return [] }
        var length = 0
        guard let pointer = omni_instance_output(instance, OMNI_VIEW_BAR, &length) else { return [] }
        let bytes = UnsafeRawBufferPointer(start: pointer, count: length)
        let header = bytes.loadUnaligned(as: omni_wire_header.self)
        return (0 ..< Int(header.node_count)).map {
            bytes.loadUnaligned(
                fromByteOffset: MemoryLayout<omni_wire_header>.stride + $0 * MemoryLayout<omni_wire_node>.stride,
                as: omni_wire_node.self
            ).width
        }
    }
}

@MainActor
final class ShellComponentPackageTests: XCTestCase {
    private let bar = ShellBarKey(monitor: .init(displayId: 95208))

    func testReaddingAnEditedRemovedModuleKeepsRootGenerationAndLoadsNewDefinition() async {
        let package = ShellWidgetPackage(name: "lake", generation: 2, outbox: ShellWidgetOutbox { _ in })
        let original = source(width: 10)
        let failure = await package.load(original)
        XCTAssertNil(failure)
        await package.receive(.bars([bar: ShellBarData()]))
        let first = await package.componentPackageWidths(bar)
        XCTAssertTrue(first.contains(10))
        await package.receive(.components(source(width: nil)))
        await package.receive(.components(original))
        let unchangedReload = await package.reloadRequested
        XCTAssertFalse(unchangedReload)
        await package.receive(.components(source(width: nil)))
        await package.receive(.components(source(width: 20)))
        await package.receive(.components(source(width: 20)))
        let changedReload = await package.reloadRequested
        XCTAssertFalse(changedReload)
        XCTAssertEqual(package.generation, 2)
        let changed = await package.componentPackageWidths(bar)
        XCTAssertTrue(changed.contains(20))
        XCTAssertFalse(changed.contains(10))
        await package.close()
    }

    func testReaddingAComponentAfterDeletingItsHelperRemovesCachedModuleWithoutRootReload() async {
        let package = ShellWidgetPackage(name: "lake", generation: 1, outbox: ShellWidgetOutbox { _ in })
        let base = source(width: 10)
        let helper = "look/widgets/custom/helper.luau"
        let original = ShellWidgetSource(
            chunk: base.chunk, main: base.main,
            modules: base.modules + [.init(path: helper, source: "return 1")],
            moduleLimit: base.moduleLimit, components: base.components
        )
        let failure = await package.load(original)
        XCTAssertNil(failure)
        await package.receive(.bars([bar: ShellBarData()]))
        await package.receive(.components(source(width: nil)))
        let removed = await package.reloadRequested
        XCTAssertFalse(removed)
        await package.receive(.components(base))
        let readded = await package.reloadRequested
        XCTAssertFalse(readded)
        let modules = await package.loadedModules
        XCTAssertFalse(modules.contains(helper))
        let widths = await package.componentPackageWidths(bar)
        XCTAssertTrue(widths.contains(10))
        await package.close()
    }

    func testRootSourceEditRequestsExactlyOneFullReload() async {
        let reloaded = expectation(description: "Root source edit requests replacement")
        var reloads = 0
        let package = ShellWidgetPackage(name: "lake", generation: 3, outbox: ShellWidgetOutbox { deliveries in
            if deliveries["lake"]?.reload == true {
                reloads += 1
                reloaded.fulfill()
            }
        })
        let original = source(width: 10)
        let failure = await package.load(original)
        XCTAssertNil(failure)
        let edited = ShellWidgetSource(
            chunk: original.chunk, main: "function render(ctx) return ui.box{w=77,h=10} end",
            modules: original.modules, moduleLimit: original.moduleLimit, components: original.components
        )
        await package.receive(.components(edited))
        await fulfillment(of: [reloaded], timeout: 5)
        await package.receive(.components(edited))
        XCTAssertEqual(reloads, 1)
        let requested = await package.reloadRequested
        XCTAssertTrue(requested)
        await package.close()
    }

    func testProfileChangeReplacesTheRootEvenWithTheSameOverrideSources() async {
        let package = ShellWidgetPackage(name: "lake", generation: 1, outbox: ShellWidgetOutbox { _ in })
        var original = source(width: 10)
        original.profile = "lake"
        let failure = await package.load(original)
        XCTAssertNil(failure)
        var next = original
        next.profile = "custom"
        await package.receive(.components(next))
        let requested = await package.reloadRequested
        XCTAssertTrue(requested)
        await package.close()
    }

    private func source(width: Int?) -> ShellWidgetSource {
        ShellWidgetSource(
            chunk: "@look/widgets/lake/init.luau",
            main: "function render(ctx) return ui.component{ id = 'one', view = 'compact' } end",
            modules: width.map {
                [.init(
                    path: "look/widgets/custom/component.luau",
                    source: "return { views = { compact = function(ctx) return ui.box{w=\($0),h=10} end } }"
                )]
            } ?? [],
            moduleLimit: 512,
            components: width == nil ? [] : [ShellComponentInstance(id: "one", widget: "custom")]
        )
    }
}
