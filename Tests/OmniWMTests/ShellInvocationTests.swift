// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import XCTest

@MainActor
final class ShellInvocationTests: XCTestCase {
    @MainActor
    private final class Sink {
        var deliveries: [ShellWidgetDelivery] = []
        var onDelivery: ((ShellWidgetDelivery) -> Void)?

        func receive(_ batch: [String: ShellWidgetDelivery]) {
            guard let delivery = batch["test"] else { return }
            deliveries.append(delivery)
            onDelivery?(delivery)
        }
    }

    private let bar = ShellBarKey(monitor: .init(displayId: 95601))
    private var key: ShellTreeKey {
        ShellTreeKey(bar: bar, view: .bar)
    }

    func testInvokeTreeIsWithheldUntilItsAcknowledgementAndPublishedAtomically() async throws {
        let sink = Sink()
        let outbox = ShellWidgetOutbox { sink.receive($0) }
        outbox.beginInvoke(name: "test", generation: 1)
        wire(epoch: 4).withUnsafeBytes {
            outbox.publish(name: "test", generation: 1, key: key, sequence: 2, output: $0)
        }
        let mainTurn = expectation(description: "main queue passed the publication boundary")
        DispatchQueue.main.async { mainTurn.fulfill() }
        await fulfillment(of: [mainTurn], timeout: 10)
        XCTAssertTrue(sink.deliveries.isEmpty)
        let delivered = expectation(description: "tree and acknowledgement delivered")
        sink.onDelivery = { _ in delivered.fulfill() }
        outbox.finishInvoke(name: "test", generation: 1, key: key, invocationID: 10, failed: false)
        await fulfillment(of: [delivered], timeout: 10)
        XCTAssertEqual(sink.deliveries.count, 1)
        let delivery = try XCTUnwrap(sink.deliveries.first)
        XCTAssertEqual(delivery.trees[key]?.sequence, 2)
        XCTAssertEqual(delivery.epoch, 4)
        XCTAssertEqual(delivery.acknowledgements[key], .init(invocationID: 10, failed: false, changed: true))
    }

    func testAcknowledgementsRemainBoundedAcrossMergesEpochChangesAndOlderGenerations() async throws {
        let delivered = expectation(description: "coalesced acknowledgements")
        let sink = Sink()
        sink.onDelivery = { _ in delivered.fulfill() }
        let outbox = ShellWidgetOutbox { sink.receive($0) }
        for id in 1 ... 300 {
            outbox.beginInvoke(name: "test", generation: 2)
            if id == 1 || id == 299 {
                wire(epoch: id == 1 ? 3 : 4).withUnsafeBytes {
                    outbox.publish(name: "test", generation: 2, key: key, sequence: id, output: $0)
                }
            }
            outbox.finishInvoke(name: "test", generation: 2, key: key, invocationID: UInt64(id), failed: id == 299)
        }
        outbox.beginInvoke(name: "test", generation: 1)
        outbox.finishInvoke(name: "test", generation: 1, key: key, invocationID: 999, failed: true)
        await fulfillment(of: [delivered], timeout: 10)
        XCTAssertEqual(sink.deliveries.count, 1)
        let delivery = try XCTUnwrap(sink.deliveries.first)
        XCTAssertEqual(delivery.generation, 2)
        XCTAssertEqual(delivery.epoch, 4)
        XCTAssertEqual(delivery.trees[key]?.sequence, 299)
        XCTAssertEqual(delivery.acknowledgements.count, 1)
        XCTAssertEqual(delivery.acknowledgements[key], .init(invocationID: 300, failed: false, changed: false))
    }

    func testPackageAcknowledgesUnchangedChangedFailedOldStaleFutureAndClosedInvocations() async throws {
        let sink = Sink()
        let package = ShellWidgetPackage(name: "test", generation: 1, outbox: ShellWidgetOutbox { sink.receive($0) })
        let failure = await package.load(source: """
        function render(ctx)
            return ui.box{w=ctx.state.width or 10,h=10,onClick=function(root,event)
                if event.key=='fail' then error('handler failed') end
                if event.key=='change' then root.state.width=20 end
            end}
        end
        """)
        XCTAssertNil(failure)
        let initial = expectation(description: "initial tree")
        sink.onDelivery = { delivery in if delivery.trees[self.key] != nil { initial.fulfill() } }
        await package.receive(.bars([bar: ShellBarData()]))
        await fulfillment(of: [initial], timeout: 10)
        var tree = try XCTUnwrap(sink.deliveries.last?.trees[key])
        for (id, operation) in [
            (UInt64(1), "noop"), (2, "change"), (3, "fail"), (4, "old"), (5, "stale"), (6, "future"), (7, "closed")
        ] {
            if operation == "closed" { await package.close() }
            let acknowledged = expectation(description: "acknowledgement \(operation)")
            sink.onDelivery = { delivery in
                if delivery.acknowledgements[self.key]?.invocationID == id { acknowledged.fulfill() }
            }
            var event = ShellEvent()
            event.key = operation
            event.invocationID = id
            let sequence = operation == "old" ? 0 : tree.sequence + (operation == "future" ? 1 : 0)
            let action = operation == "stale" ? UInt32.max : node(tree).action
            await package.receive(.invoke(bar, .bar, action: action, sequence: sequence, event: event))
            await fulfillment(of: [acknowledged], timeout: 10)
            let delivery = try XCTUnwrap(sink.deliveries.last)
            let ack = try XCTUnwrap(delivery.acknowledgements[key])
            XCTAssertEqual(ack.invocationID, id)
            XCTAssertEqual(ack.failed, ["fail", "stale", "future", "closed"].contains(operation))
            if operation == "stale" { XCTAssertNil(delivery.failure) }
            XCTAssertEqual(ack.changed, operation == "change")
            if operation == "change" {
                tree = try XCTUnwrap(delivery.trees[key])
                XCTAssertEqual(node(tree).width, 20)
            } else { XCTAssertNil(delivery.trees[key]) }
        }
        await package.close()
    }

    func testRenderFailureAndMissingInstanceStillProduceCompletion() async throws {
        let sink = Sink()
        let package = ShellWidgetPackage(name: "test", generation: 1, outbox: ShellWidgetOutbox { sink.receive($0) })
        let failure = await package.load(source: """
        function render(ctx)
            if ctx.state.broken then error('render failed') end
            return ui.box{w=10,h=10,onClick=function(root) root.state.broken=true end}
        end
        """)
        XCTAssertNil(failure)
        let initial = expectation(description: "initial tree")
        sink.onDelivery = { delivery in if delivery.trees[self.key] != nil { initial.fulfill() } }
        await package.receive(.bars([bar: ShellBarData()]))
        await fulfillment(of: [initial], timeout: 10)
        let tree = try XCTUnwrap(sink.deliveries.last?.trees[key])
        for (id, target) in [(UInt64(1), bar), (2, ShellBarKey(monitor: .init(displayId: 95602)))] {
            let done = expectation(description: "failed completion \(id)")
            let source = ShellTreeKey(bar: target, view: .bar)
            sink.onDelivery = { delivery in
                if delivery.acknowledgements[source]?.invocationID == id { done.fulfill() }
            }
            var event = ShellEvent()
            event.invocationID = id
            await package.receive(.invoke(
                target,
                .bar,
                action: node(tree).action,
                sequence: tree.sequence,
                event: event
            ))
            await fulfillment(of: [done], timeout: 10)
            let delivery = try XCTUnwrap(sink.deliveries.last)
            XCTAssertEqual(delivery.acknowledgements[source], .init(invocationID: id, failed: true, changed: false))
            XCTAssertTrue(delivery.trees.isEmpty)
            if id == 1 { XCTAssertNotNil(delivery.failure) }
        }
        await package.close()
    }

    func testCoalescedChangedSamplesCannotMovePastSealedEndedInvocation() throws {
        let box = ShellGestureBox()
        func gesture(_ id: UInt64) -> ShellGestureBox.Gesture {
            var event = ShellEvent()
            event.kind = .gesture
            event.phase = .changed
            event.invocationID = id
            event.dx = Double(id)
            return ShellGestureBox.Gesture(bar: bar, view: .bar, action: 1, sequence: 1, event: event)
        }
        let first = try XCTUnwrap(box.post(gesture(1)))
        XCTAssertNil(box.post(gesture(2)))
        box.seal()
        let later = try XCTUnwrap(box.post(gesture(4)))
        XCTAssertEqual(first.take()?.event.invocationID, 2)
        XCTAssertEqual(later.take()?.event.invocationID, 4)
    }

    func testStaleHostRejectionSettlesTheOriginatingGesture() throws {
        let resources = ShellResources(motion: MotionPolicy(animationsEnabled: false))
        let host = ShellWidgetHost(
            configDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            resources: resources, world: { ShellWorldData() }, vars: { [:] }, bars: { [:] }, onLayoutChange: {},
            onCommand: { _, _ in }, onMenu: { _ in }, onPreview: { _ in }, onDrag: { _ in },
            onPopoutChange: {}, onTitleDemandChange: { _ in }
        )
        let script = try ShellScriptHostTests.Script("""
        function render(ctx)
            return ui.box{w=40,h=20,gesture={axis='x',commit={distance=20},track={dx={0,20}}},onGesture=function() end}
        end
        """)
        let surface = ShellWidgetSurface(scale: 2, resources: resources, directories: [])
        let text = ShellTextStore()
        XCTAssertEqual(script.render().status, OMNI_OK)
        text.ingest(wire: script.output)
        XCTAssertTrue(surface.apply(script.output, text: text))
        let state = ShellWidgetHost.WidgetState(name: "test", sourceURL: URL(fileURLWithPath: "/unused"))
        surface.onAction = { [weak surface] click in host.perform(
            click,
            view: .bar,
            key: self.bar,
            for: state,
            from: surface
        ) }
        surface.press(at: CGPoint(x: 3, y: 2), timestamp: 0)
        surface.drag(to: CGPoint(x: 28, y: 2), screen: .zero, timestamp: 0.01)
        surface.release(at: CGPoint(x: 28, y: 2), timestamp: 0.02)
        XCTAssertNil(surface.gestureTracking)
        let scene = surface.scene
        let slot = surface.layout.core.rootHandle.slot
        XCTAssertEqual(ShellLayerScene.engineQueue.sync { scene.gestureLayers[slot]?.layer.transform.m41 }, 0)
    }

    private func wire(epoch: UInt32) -> [UInt8] {
        var header = omni_wire_header(
            magic: OMNI_WIRE_MAGIC,
            node_count: 0,
            string_count: 0,
            flags: 0,
            deps: 0,
            epoch: epoch
        )
        return withUnsafeBytes(of: &header) { Array($0) }
    }

    private func node(_ tree: ShellWidgetDelivery.Tree) -> omni_wire_node {
        tree.nodes.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: MemoryLayout<omni_wire_header>.stride, as: omni_wire_node.self)
        }
    }
}
