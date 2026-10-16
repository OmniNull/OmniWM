// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMScriptHost
import XCTest

private struct ShellInvalidationSnapshot: Sendable {
    let sequence: Int
    let width: Float
    let action: UInt32
    let bytes: Int
    let pendingData: UInt64
    let invalidations: UInt64
}

private extension ShellWidgetPackage {
    func invalidationSnapshot(_ key: ShellBarKey, view: ShellWidgetView) -> ShellInvalidationSnapshot? {
        guard let script, let instance = script.instances[key], let state = states[key] else { return nil }
        var count = 0
        guard let output = omni_instance_output(instance, view.wire, &count),
              count >= MemoryLayout<omni_wire_header>.stride + MemoryLayout<omni_wire_node>.stride
        else { return nil }
        let node = UnsafeRawPointer(output).loadUnaligned(
            fromByteOffset: MemoryLayout<omni_wire_header>.stride,
            as: omni_wire_node.self
        )
        return ShellInvalidationSnapshot(
            sequence: state.sequences[view.rawValue],
            width: node.width,
            action: node.action,
            bytes: omni_vm_bytes_in_use(script.vm),
            pendingData: state.pendingData,
            invalidations: state.invalidations[view.rawValue]
        )
    }

    func allowNextTimedRender() {
        lastTimedRender = nil
    }
}

@MainActor
final class ShellWidgetInvalidationTests: XCTestCase {
    private static let bar = ShellBarKey(monitor: Monitor.ID(displayId: 92_405))

    private func package(_ source: String, data: ShellWidgetData = ShellWidgetData()) async -> ShellWidgetPackage {
        let package = ShellWidgetPackage(name: "test", generation: 1, outbox: ShellWidgetOutbox { _ in })
        let failure = await package.load(source: source)
        XCTAssertNil(failure)
        await package.receive(.update(data))
        await package.receive(.bars([Self.bar: ShellBarData()]))
        return package
    }

    private func snapshot(
        _ package: ShellWidgetPackage,
        view: ShellWidgetView = .bar
    ) async throws -> ShellInvalidationSnapshot {
        let value = await package.invalidationSnapshot(Self.bar, view: view)
        return try XCTUnwrap(value)
    }

    func testUnobservedCompositeUpdatesLeaveTheVMHeapUntouched() async throws {
        let package = await package("""
        local renders = 0
        function render(ctx)
            renders += 1
            return ui.box{ w = #ctx.data.clock + renders * 100, h = 10 }
        end
        """)
        let before = try await snapshot(package)
        var data = ShellWidgetData()
        for index in 1 ... 8 {
            data.vars = ["latest": String(repeating: "value\(index)", count: 1024)]
            data.media = ShellMedia(title: "Track \(index)", elapsed: Double(index))
            await package.receive(.update(data))
        }
        let after = try await snapshot(package)
        XCTAssertEqual(after.sequence, before.sequence)
        XCTAssertEqual(after.width, before.width)
        XCTAssertEqual(after.bytes, before.bytes)
        XCTAssertEqual(after.pendingData, ShellDataKey.vars.bit | ShellDataKey.media.bit)
        await package.close()
    }

    func testTriggerAndClickReadTheLatestDeferredValues() async throws {
        let package = await package("""
        function render(ctx)
            return ui.box{ w = ctx.state.seen or 1, h = 10,
                onClick = function(ctx) ctx.state.seen = tonumber(ctx.data.vars.latest) end }
        end
        function trigger(ctx, event)
            ctx.state.seen = tonumber(ctx.data.vars.latest)
        end
        """)
        var data = ShellWidgetData()
        data.vars = ["latest": "37"]
        await package.receive(.update(data))
        let deferred = try await snapshot(package)
        XCTAssertEqual(deferred.sequence, 1)
        XCTAssertEqual(deferred.pendingData, ShellDataKey.vars.bit)
        await package.receive(.trigger(name: "refresh", value: nil))
        let triggered = try await snapshot(package)
        XCTAssertEqual(triggered.width, 37)
        XCTAssertEqual(triggered.pendingData, 0)

        data.vars = ["latest": "49"]
        await package.receive(.update(data))
        await package.receive(.invoke(
            Self.bar,
            .bar,
            action: triggered.action,
            sequence: triggered.sequence,
            event: ShellEvent()
        ))
        let clicked = try await snapshot(package)
        XCTAssertEqual(clicked.width, 49)
        XCTAssertEqual(clicked.pendingData, 0)
        await package.close()
    }

    func testTheFirstPopoutReadsTheLatestPreviouslyUnobservedValue() async throws {
        let package = await package("""
        function render(ctx) return ui.box{ w = 1, h = 10 } end
        function popout(ctx) return ui.box{ w = tonumber(ctx.data.vars.latest), h = 10 } end
        """)
        var data = ShellWidgetData()
        for value in [7, 43] {
            data.vars = ["latest": String(value)]
            await package.receive(.update(data))
        }
        let before = try await snapshot(package)
        XCTAssertEqual(before.sequence, 1)
        XCTAssertEqual(before.pendingData, ShellDataKey.vars.bit)
        await package.receive(.popout(Self.bar, true))
        let opened = try await snapshot(package, view: .popout)
        XCTAssertEqual(opened.sequence, 1)
        XCTAssertEqual(opened.width, 43)
        XCTAssertEqual(opened.pendingData, 0)
        await package.close()
    }

    func testMediaTitleSelectionSkipsElapsedUpdatesAndRendersTitleChanges() async throws {
        var data = ShellWidgetData()
        data.media = ShellMedia(title: "First", elapsed: 1)
        let package = await package("""
        local renders = 0
        function render(ctx)
            renders += 1
            return ui.box{ w = #ctx.select("media", "title") + renders * 100, h = 10 }
        end
        """, data: data)
        let first = try await snapshot(package)
        XCTAssertEqual(first.width, 105)
        data.media?.elapsed = 2
        await package.receive(.update(data))
        let elapsed = try await snapshot(package)
        XCTAssertEqual(elapsed.sequence, 1)
        XCTAssertEqual(elapsed.width, 105)
        data.media?.title = "Second"
        await package.receive(.update(data))
        let title = try await snapshot(package)
        XCTAssertEqual(title.sequence, 2)
        XCTAssertEqual(title.width, 206)
        await package.close()
    }

    func testBarAndPopoutKeepIndependentSelectionsAndInvalidations() async throws {
        var data = ShellWidgetData()
        data.media = ShellMedia(title: "First", elapsed: 1)
        let package = await package("""
        local bars, popouts = 0, 0
        function render(ctx)
            bars += 1
            return ui.box{ w = #ctx.select("media", "title") + bars * 100, h = 10 }
        end
        function popout(ctx)
            popouts += 1
            return ui.box{ w = ctx.select("media", "elapsed") + popouts * 100, h = 10 }
        end
        """, data: data)
        await package.receive(.popout(Self.bar, true))
        data.media?.elapsed = 2
        await package.receive(.update(data))
        let barAfterElapsed = try await snapshot(package)
        let popoutAfterElapsed = try await snapshot(package, view: .popout)
        XCTAssertEqual(barAfterElapsed.sequence, 1)
        XCTAssertEqual(barAfterElapsed.width, 105)
        XCTAssertEqual(popoutAfterElapsed.sequence, 2)
        XCTAssertEqual(popoutAfterElapsed.width, 202)

        data.media?.title = "Second"
        await package.receive(.update(data))
        let barAfterTitle = try await snapshot(package)
        let popoutAfterTitle = try await snapshot(package, view: .popout)
        XCTAssertEqual(barAfterTitle.sequence, 2)
        XCTAssertEqual(barAfterTitle.width, 206)
        XCTAssertEqual(popoutAfterTitle.sequence, 2)
        XCTAssertEqual(popoutAfterTitle.width, 202)
        await package.close()
    }

    func testPacedInvalidationSurvivesUntilAnEligibleUnchangedDelivery() async throws {
        var data = ShellWidgetData()
        data.seconds = 1
        let package = await package("""
        local renders = 0
        function render(ctx)
            renders += 1
            return ui.box{ w = ctx.data.seconds + renders * 100, h = 10 }
        end
        """, data: data)
        await package.receive(.interval(3600))
        await package.receive(.update(data))
        data.seconds = 2
        await package.receive(.update(data))
        await package.receive(.update(data))
        let held = try await snapshot(package)
        XCTAssertEqual(held.sequence, 1)
        XCTAssertEqual(held.width, 101)
        XCTAssertEqual(held.pendingData, ShellDataKey.seconds.bit)
        XCTAssertNotEqual(held.invalidations & ShellDataKey.seconds.bit, 0)

        await package.allowNextTimedRender()
        await package.receive(.update(data))
        let resumed = try await snapshot(package)
        XCTAssertEqual(resumed.sequence, 2)
        XCTAssertEqual(resumed.width, 202)
        XCTAssertEqual(resumed.pendingData, 0)
        XCTAssertEqual(resumed.invalidations, 0)
        await package.close()
    }

    func testBarMetadataChangesDoNotInvalidateASelectedStyleField() async throws {
        let package = await package("""
        local renders = 0
        function render(ctx)
            renders += 1
            return ui.box{ w = ctx.select("bar", "style", "height") + renders * 100, h = 10 }
        end
        """)
        var bar = ShellBarData()
        bar.monitor = "Renamed display"
        bar.workspaces = [ShellBarWorkspace(id: "one", name: "One", focused: true, windows: [])]
        await package.receive(.bars([Self.bar: bar]))
        let metadata = try await snapshot(package)
        XCTAssertEqual(metadata.sequence, 1)
        XCTAssertEqual(metadata.width, 124)
        bar.style.height = 30
        await package.receive(.bars([Self.bar: bar]))
        let style = try await snapshot(package)
        XCTAssertEqual(style.sequence, 2)
        XCTAssertEqual(style.width, 230)
        await package.close()
    }
}
