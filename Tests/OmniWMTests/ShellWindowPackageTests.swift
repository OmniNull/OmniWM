// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMScriptHost
import XCTest

private struct ShellWindowNodeSnapshot: Sendable {
    let width: Float
    let height: Float
    let action: UInt32
}

private struct ShellWindowPackageSnapshot: Sendable {
    let nodes: [ShellWindowNodeSnapshot]
    let sequence: Int
}

private extension ShellWidgetPackage {
    func windowSnapshot(_ id: UUID) -> ShellWindowPackageSnapshot? {
        let key = ShellInstanceKey.window(id)
        guard let instance = script?.instances[key], let state = states[key] else { return nil }
        var length = 0
        guard let pointer = omni_instance_output(instance, OMNI_VIEW_WINDOW, &length),
              length >= MemoryLayout<omni_wire_header>.stride else { return nil }
        let bytes = UnsafeRawBufferPointer(start: pointer, count: length)
        let header = bytes.loadUnaligned(as: omni_wire_header.self)
        let nodes = (0 ..< Int(header.node_count)).map { index in
            let node = bytes.loadUnaligned(
                fromByteOffset: MemoryLayout<omni_wire_header>.stride + index * MemoryLayout<omni_wire_node>.stride,
                as: omni_wire_node.self
            )
            return ShellWindowNodeSnapshot(width: node.width, height: node.height, action: node.action)
        }
        return ShellWindowPackageSnapshot(nodes: nodes, sequence: state.sequences[ShellWidgetView.window.rawValue])
    }

    func windowInstanceCount() -> Int {
        script?.instances.keys.filter { if case .window = $0 { true } else { false } }.count ?? 0
    }
}

@MainActor
final class ShellWindowPackageTests: XCTestCase {
    func testTheBundledExampleRendersItsNamedWindowViewAtTheOfferedContentSize() async throws {
        let definition = try XCTUnwrap(ShellAppDefinition.example)
        let package = makePackage(definition)
        let failure = await package.load(try definition.source())
        XCTAssertNil(failure)
        let context = context(size: definition.contentSize)

        await package.receive(.window(context))

        let value = await package.windowSnapshot(context.id)
        let snapshot = try XCTUnwrap(value)
        XCTAssertTrue(snapshot.nodes
            .contains { $0.width == Float(context.width) && $0.height == Float(context.height) })
        XCTAssertTrue(snapshot.nodes.contains { $0.action != 0 })
        await package.close()
    }

    func testTheWindowRootReceivesItsOwnViewOfferWithoutADataKey() async throws {
        let definition = try XCTUnwrap(ShellAppDefinition.example)
        let package = makePackage(definition)
        let source = ShellWidgetSource(chunk: "=window-view", main: """
        function window(ctx)
            assert(ctx.view.name == "window")
            assert(table.isfrozen(ctx.view))
            assert(ctx.data.windowSize == nil)
            return ui.box{ w = ctx.view.w, h = ctx.view.h }
        end
        """, modules: [])
        let failure = await package.load(source)
        XCTAssertNil(failure)
        let original = context(size: definition.contentSize)
        await package.receive(.window(original))
        let initialValue = await package.windowSnapshot(original.id)
        let initial = try XCTUnwrap(initialValue)
        let resized = ShellWindowContext(
            id: original.id, width: definition.minimumContentSize.width,
            height: definition.minimumContentSize.height, visible: true
        )

        await package.receive(.window(resized))

        let resizedValue = await package.windowSnapshot(original.id)
        let snapshot = try XCTUnwrap(resizedValue)
        XCTAssertGreaterThan(snapshot.sequence, initial.sequence)
        XCTAssertTrue(snapshot.nodes
            .contains { $0.width == Float(resized.width) && $0.height == Float(resized.height) })
        await package.close()
    }

    func testResizeReusesTheComponentStateAndUpdatesBothViewDimensions() async throws {
        let definition = try XCTUnwrap(ShellAppDefinition.example)
        let package = makePackage(definition)
        let failure = await package.load(try measuringSource(definition))
        XCTAssertNil(failure)
        let original = context(size: definition.contentSize)
        await package.receive(.window(original))
        let initialValue = await package.windowSnapshot(original.id)
        let initial = try XCTUnwrap(initialValue)
        let action = try XCTUnwrap(initial.nodes.first { $0.action != 0 }?.action)
        await package.receive(.invoke(
            .window(original.id), .window, action: action, sequence: initial.sequence, event: ShellEvent()
        ))
        let resized = ShellWindowContext(
            id: original.id, width: definition.minimumContentSize.width,
            height: definition.minimumContentSize.height, visible: true
        )

        await package.receive(.window(resized))

        let value = await package.windowSnapshot(original.id)
        let snapshot = try XCTUnwrap(value)
        XCTAssertTrue(snapshot.nodes
            .contains { $0.width == Float(resized.width) && $0.height == Float(resized.height) })
        XCTAssertTrue(snapshot.nodes.contains {
            $0.width == Float(original.width) && $0.height == Float(resized.height / 2)
        })
        XCTAssertGreaterThan(snapshot.sequence, initial.sequence)
        let count = await package.windowInstanceCount()
        XCTAssertEqual(count, [original.id].count)
        await package.close()
    }

    func testRemovingTheWindowDestroysItsStateAndClosingRejectsLateMessages() async throws {
        let definition = try XCTUnwrap(ShellAppDefinition.example)
        let package = makePackage(definition)
        let failure = await package.load(try measuringSource(definition))
        XCTAssertNil(failure)
        let original = context(size: definition.contentSize)
        await package.receive(.window(original))
        let initialValue = await package.windowSnapshot(original.id)
        let initial = try XCTUnwrap(initialValue)
        let action = try XCTUnwrap(initial.nodes.first { $0.action != 0 }?.action)
        await package.receive(.invoke(
            .window(original.id), .window, action: action, sequence: initial.sequence, event: ShellEvent()
        ))

        await package.receive(.removeWindow(original.id))
        let removed = await package.windowSnapshot(original.id)
        XCTAssertNil(removed)
        await package.receive(.window(original))
        let reopenedValue = await package.windowSnapshot(original.id)
        let reopened = try XCTUnwrap(reopenedValue)
        XCTAssertTrue(reopened.nodes.contains {
            $0.width == Float(original.width / 2) && $0.height == Float(original.height / 2)
        })
        await package.close()
        await package.receive(.window(original))
        let closed = await package.windowSnapshot(original.id)
        XCTAssertNil(closed)
        let count = await package.windowInstanceCount()
        XCTAssertEqual(count, Set<UUID>().count)
    }

    private func makePackage(_ definition: ShellAppDefinition) -> ShellWidgetPackage {
        ShellWidgetPackage(name: definition.id, generation: 1, outbox: ShellWidgetOutbox { deliveries in
            XCTAssertNil(deliveries[definition.id]?.failure)
        })
    }

    private func context(size: CGSize) -> ShellWindowContext {
        ShellWindowContext(id: UUID(), width: size.width, height: size.height, visible: true)
    }

    private func measuringSource(_ definition: ShellAppDefinition) throws -> ShellWidgetSource {
        var source = try definition.source()
        source = ShellWidgetSource(
            chunk: source.chunk, main: source.main,
            modules: [.init(path: source.modules[0].path, source: """
            return { views = { window = function(ctx)
                return ui.box{ w = ctx.view.w, h = ctx.view.h,
                    onClick = function(next) next.state.value = next.view.w end,
                    ui.box{ w = ctx.state.value or ctx.view.w / 2, h = ctx.view.h / 2 } }
            end } }
            """)], components: source.components, componentDescriptors: source.componentDescriptors,
            assetPackages: source.assetPackages, profile: source.profile, principal: source.principal
        )
        return source
    }
}
