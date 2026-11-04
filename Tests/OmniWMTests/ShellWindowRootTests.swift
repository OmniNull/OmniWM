// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMScriptHost
import XCTest

private extension ShellWidgetPackage {
    func windowRootIDs() -> Set<UUID> {
        Set(script?.instances.keys.compactMap { key in
            if case let .window(id) = key { id } else { nil }
        } ?? [])
    }
}

@MainActor
final class ShellWindowRootTests: XCTestCase {
    private let mainView = "window"
    private let childView = "confirm"
    private let initialShared = 10
    private let initialLocal = 3
    private let sharedIncrement = 5
    private let localIncrement = 2

    private final class Sink {
        var text = ShellTextStore()
        var epoch = 0
        var trees: [UUID: ShellWidgetDelivery.Tree] = [:]
        var remaining: Set<UUID> = []
        var completed: (() -> Void)?

        func receive(_ delivery: ShellWidgetDelivery) {
            if let failure = delivery.failure {
                XCTFail(failure.message)
                completed?()
                completed = nil
                return
            }
            if delivery.epoch != epoch {
                epoch = delivery.epoch
                text = ShellTextStore()
            }
            text.ingest(delivery.strings, count: delivery.stringCount)
            for (key, tree) in delivery.trees {
                guard case let .window(id) = key.instance, key.view == .window else { continue }
                trees[id] = tree
                remaining.remove(id)
            }
            if remaining.isEmpty {
                completed?()
                completed = nil
            }
        }

        func nodes(_ id: UUID) throws -> [omni_wire_node] {
            let tree = try XCTUnwrap(trees[id])
            return tree.nodes.withUnsafeBytes { bytes in
                let header = bytes.loadUnaligned(as: omni_wire_header.self)
                return (0 ..< Int(header.node_count)).map { index in
                    bytes.loadUnaligned(
                        fromByteOffset: MemoryLayout<omni_wire_header>.stride
                            + index * MemoryLayout<omni_wire_node>.stride,
                        as: omni_wire_node.self
                    )
                }
            }
        }

        func captions(_ id: UUID) throws -> [String] {
            try nodes(id).filter { $0.text != 0 }.map { text.string($0.text) }
        }

        func invocation(_ id: UUID) throws -> ShellWidgetMessage {
            let tree = try XCTUnwrap(trees[id])
            let action = try XCTUnwrap(try nodes(id).first { $0.action != 0 }?.action)
            return .invoke(.window(id), .window, action: action, sequence: tree.sequence, event: ShellEvent())
        }
    }

    func testTwoWindowRootsShareTheAppModelAndKeepLocalStateThroughIndependentOffersAndRemoval() async throws {
        let definition = try XCTUnwrap(ShellAppDefinition.example)
        let sink = Sink()
        let package = makePackage(sink)
        let failure = await package.load(source(definition))
        XCTAssertNil(failure)
        let main = ShellWindowContext(
            id: UUID(), width: definition.contentSize.width, height: definition.contentSize.height,
            visible: true, viewName: mainView
        )
        let child = ShellWindowContext(
            id: UUID(), width: definition.minimumContentSize.width, height: definition.minimumContentSize.height,
            visible: true, viewName: childView
        )
        await publish(.window(main), through: package, to: sink, roots: [main.id])
        await publish(.window(child), through: package, to: sink, roots: [child.id])
        let rootIDs = await package.windowRootIDs()
        XCTAssertEqual(rootIDs, [main.id, child.id])
        try assertContent(main, shared: initialShared, local: initialLocal, in: sink)
        try assertContent(child, shared: initialShared, local: initialLocal, in: sink)

        await publish(try sink.invocation(main.id), through: package, to: sink, roots: [main.id, child.id])

        try assertContent(main, shared: initialShared + sharedIncrement, local: initialLocal + localIncrement, in: sink)
        try assertContent(child, shared: initialShared + sharedIncrement, local: initialLocal, in: sink)
        let resized = ShellWindowContext(
            id: child.id, width: child.width + main.width, height: child.height + main.height,
            visible: true, viewName: childView
        )
        await publish(.window(resized), through: package, to: sink, roots: [child.id])
        try assertContent(resized, shared: initialShared + sharedIncrement, local: initialLocal, in: sink)
        try assertContent(main, shared: initialShared + sharedIncrement, local: initialLocal + localIncrement, in: sink)
        let retiredAction = try sink.invocation(child.id)
        await package.receive(.removeWindow(child.id))
        await package.receive(.removeWindow(child.id))
        let remaining = await package.windowRootIDs()
        XCTAssertEqual(remaining, [main.id])
        let mainSequence = try XCTUnwrap(sink.trees[main.id]?.sequence)
        await package.receive(retiredAction)
        XCTAssertEqual(sink.trees[main.id]?.sequence, mainSequence)
        let reopened = ShellWindowContext(
            id: UUID(), width: child.width, height: child.height, visible: true, viewName: childView
        )
        await publish(.window(reopened), through: package, to: sink, roots: [reopened.id])
        try assertContent(reopened, shared: initialShared + sharedIncrement, local: initialLocal, in: sink)
        await publish(try sink.invocation(reopened.id), through: package, to: sink, roots: [main.id, reopened.id])
        try assertContent(
            main,
            shared: initialShared + sharedIncrement * 2,
            local: initialLocal + localIncrement,
            in: sink
        )
        try assertContent(
            reopened,
            shared: initialShared + sharedIncrement * 2,
            local: initialLocal + localIncrement,
            in: sink
        )
        await package.close()
        await package.receive(.window(child))
        let closed = await package.windowRootIDs()
        XCTAssertTrue(closed.isEmpty)
    }

    func testSharedOnlyActionRefreshesBothRootsWithoutChangingLocalState() async throws {
        let definition = try XCTUnwrap(ShellAppDefinition.example)
        let sink = Sink()
        let package = makePackage(sink)
        let failure = await package.load(source(definition, updatesLocal: false))
        XCTAssertNil(failure)
        let main = ShellWindowContext(
            id: UUID(), width: definition.contentSize.width, height: definition.contentSize.height,
            visible: true, viewName: mainView
        )
        let child = ShellWindowContext(
            id: UUID(), width: definition.minimumContentSize.width, height: definition.minimumContentSize.height,
            visible: true, viewName: childView
        )
        await publish(.window(main), through: package, to: sink, roots: [main.id])
        await publish(.window(child), through: package, to: sink, roots: [child.id])
        try assertContent(main, shared: initialShared, local: initialLocal, in: sink)
        try assertContent(child, shared: initialShared, local: initialLocal, in: sink)

        await publish(try sink.invocation(main.id), through: package, to: sink, roots: [main.id, child.id])

        try assertContent(main, shared: initialShared + sharedIncrement, local: initialLocal, in: sink)
        try assertContent(child, shared: initialShared + sharedIncrement, local: initialLocal, in: sink)
        await package.close()
    }

    func testChangingOnlyTheNamedOfferKeepsRootLocalStateAndRejectsInvalidOffers() async throws {
        let definition = try XCTUnwrap(ShellAppDefinition.example)
        let sink = Sink()
        let package = makePackage(sink)
        let failure = await package.load(source(definition))
        XCTAssertNil(failure)
        let original = ShellWindowContext(
            id: UUID(), width: definition.contentSize.width, height: definition.contentSize.height,
            visible: true, viewName: mainView
        )
        await publish(.window(original), through: package, to: sink, roots: [original.id])
        await publish(try sink.invocation(original.id), through: package, to: sink, roots: [original.id])
        var named = original
        named.viewName = childView
        await publish(.window(named), through: package, to: sink, roots: [named.id])
        try assertContent(
            named,
            shared: initialShared + sharedIncrement,
            local: initialLocal + localIncrement,
            in: sink
        )
        let sequence = try XCTUnwrap(sink.trees[named.id]?.sequence)
        for invalidName in ["", ".hidden", "bad/view", "bad\\view", "bad:view", "bad\0view"] {
            var invalid = named
            invalid.viewName = invalidName
            await package.receive(.window(invalid))
        }
        await package.receive(.window(ShellWindowContext(
            id: UUID(), width: .nan, height: named.height, visible: true, viewName: childView
        )))
        let roots = await package.windowRootIDs()
        XCTAssertEqual(roots, [original.id])
        XCTAssertEqual(sink.trees[named.id]?.sequence, sequence)
        await package.close()
    }

    func testRetiredChildDeliveryCannotUpdateParentOrReopenedRuntimeSlot() async throws {
        let fixture = try HostedManagementFixture()
        defer { fixture.close() }
        let parent = try fixture.open()
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
        let child = try await openHostedSheet(parent, fixture: fixture)
        let retiredSequence = child.slot.renderedSequence
        try await closeHostedSheet(child, button: "Cancel", parent: parent, fixture: fixture)
        let parentSequence = parent.session.renderedSequence
        var late = ShellWidgetDelivery(generation: ShellAppRuntime.generation)
        late.trees[ShellTreeKey(instance: .window(child.metadata.rootID), view: .window)] = .init(
            sequence: retiredSequence + 1
        )

        parent.session.receive(late)

        XCTAssertNil(parent.session.slots[child.metadata.rootID])
        XCTAssertEqual(child.slot.renderedSequence, retiredSequence)
        XCTAssertEqual(parent.session.renderedSequence, parentSequence)
        let reopened = try await openHostedSheet(parent, fixture: fixture)
        XCTAssertNotEqual(reopened.metadata.rootID, child.metadata.rootID)
        let reopenedSequence = reopened.slot.renderedSequence
        let currentParentSequence = parent.session.renderedSequence

        parent.session.receive(late)

        XCTAssertNil(parent.session.slots[child.metadata.rootID])
        XCTAssertEqual(child.slot.renderedSequence, retiredSequence)
        XCTAssertEqual(reopened.slot.renderedSequence, reopenedSequence)
        XCTAssertEqual(parent.session.renderedSequence, currentParentSequence)
        XCTAssertTrue(parent.session.slots[reopened.metadata.rootID] === reopened.slot)
        fixture.close()
        await ShellWidgetHost.flushRetiredWork()
    }

    func testWindowOfferBridgeRejectsInvalidNamesAndGeometry() throws {
        let vm = try XCTUnwrap(ShellVM.make(memoryLimit: ShellWidgetPackage.memoryLimit))
        defer { _ = omni_vm_destroy(vm) }
        let script = "function window(ctx) return ui.box{w=ctx.view.w,h=ctx.view.h} end"
        var error = [CChar](repeating: 0, count: 512)
        XCTAssertEqual(omni_vm_load(
            vm, "=window-offer", script, script.utf8.count, ShellWidgetPackage.loadBudget, &error, error.count
        ), OMNI_OK)
        let instance = try XCTUnwrap(omni_instance_create(vm))
        defer { omni_instance_destroy(instance) }
        let definition = try XCTUnwrap(ShellAppDefinition.example)
        let size = definition.contentSize
        XCTAssertEqual(omni_instance_set_window_offer(
            instance, childView, childView.utf8.count, size.width, size.height
        ), OMNI_OK)
        for invalidName in ["", ".hidden", "bad/view", "bad\\view", "bad:view", "bad\0view"] {
            XCTAssertEqual(omni_instance_set_window_offer(
                instance, invalidName, invalidName.utf8.count, size.width, size.height
            ), OMNI_ERR_INTERNAL)
        }
        XCTAssertEqual(
            omni_instance_set_window_offer(instance, nil, childView.utf8.count, size.width, size.height),
            OMNI_ERR_INTERNAL
        )
        for invalidWidth in [Double.nan, .infinity, .zero, -size.width] {
            XCTAssertEqual(omni_instance_set_window_offer(
                instance, childView, childView.utf8.count, invalidWidth, size.height
            ), OMNI_ERR_INTERNAL)
        }
    }

    private func makePackage(_ sink: Sink) -> ShellWidgetPackage {
        ShellWidgetPackage(name: "window-roots", generation: 1, outbox: ShellWidgetOutbox { deliveries in
            if let delivery = deliveries["window-roots"] { sink.receive(delivery) }
        })
    }

    private func publish(
        _ message: ShellWidgetMessage, through package: ShellWidgetPackage, to sink: Sink, roots: Set<UUID>
    ) async {
        let published = expectation(description: "All declared window roots publish")
        let failureDeadline: TimeInterval = 10
        sink.remaining = roots
        sink.completed = { published.fulfill() }
        await package.receive(message)
        await fulfillment(of: [published], timeout: failureDeadline)
        sink.completed = nil
        XCTAssertTrue(sink.remaining.isEmpty)
    }

    private func assertContent(
        _ context: ShellWindowContext, shared: Int, local: Int, in sink: Sink
    ) throws {
        XCTAssertEqual(try sink.captions(context.id), ["\(context.viewName):\(shared):\(local)"])
        XCTAssertTrue(try sink.nodes(context.id).contains {
            $0.width == Float(context.width) && $0.height == Float(context.height)
        })
    }

    private func source(_ definition: ShellAppDefinition, updatesLocal: Bool = true) -> ShellWidgetSource {
        let updateLocal = updatesLocal
            ? "next.state.value = (next.state.value or \(initialLocal)) + \(localIncrement)" : ""
        let component = """
        local component = { views = {} }
        function component.init(instance) instance.state.shared = \(initialShared) end
        local function view(ctx)
            return ui.box{w=ctx.view.w,h=ctx.view.h,
                ui.text{text=ctx.view.name .. ':' .. ctx.instance.state.shared .. ':' .. (ctx.state.value or \(initialLocal)),
                    onClick=function(next)
                        next.instance.state.shared += \(sharedIncrement)
                        \(updateLocal)
                    end}}
        end
        component.views.\(mainView) = view
        component.views.\(childView) = view
        return component
        """
        return ShellWidgetSource(
            chunk: "@widgets/window-roots/init.luau",
            main: "function window(ctx) return ui.component{id='app',view=ctx.view.name,w=ctx.view.w,h=ctx.view.h} end",
            modules: [.init(path: "widgets/window-roots/component.luau", source: component)],
            components: [.init(id: "app", widget: "window-roots")],
            componentDescriptors: [.init(
                widget: "window-roots", title: "Window Roots", icon: "app", views: [mainView, childView], uses: [],
                options: [:], capabilities: ShellComponentCapabilities(), providerCommand: nil,
                folder: definition.folder
            )]
        )
    }
}
