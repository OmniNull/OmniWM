// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMScriptHost
import XCTest

private struct ShellIslandRenderSnapshot: Sendable {
    let sequence: Int
    let width: Float?
    let height: Float?
}

private extension ShellWidgetPackage {
    func islandRenderSnapshot(_ key: ShellBarKey) -> ShellIslandRenderSnapshot? {
        guard let instance = script?.instances[key], let state = states[key] else { return nil }
        var count = 0
        var node: omni_wire_node?
        if let output = omni_instance_output(instance, OMNI_VIEW_BAR, &count),
           count >= MemoryLayout<omni_wire_header>.stride + MemoryLayout<omni_wire_node>.stride
        {
            node = UnsafeRawPointer(output).loadUnaligned(
                fromByteOffset: MemoryLayout<omni_wire_header>.stride,
                as: omni_wire_node.self
            )
        }
        return ShellIslandRenderSnapshot(sequence: state.sequences[0], width: node?.width, height: node?.height)
    }
}

@MainActor
final class ShellIslandPackageTests: XCTestCase {
    func testHiddenIslandRetainsStateAndResumesOnceWithLatestData() async throws {
        let monitor = monitor()
        let bar = ShellBarKey(monitor: monitor.id)
        let island = ShellBarKey(monitor: monitor.id, placement: .island)
        let package = ShellWidgetPackage(name: "island", generation: 1, outbox: ShellWidgetOutbox { _ in })
        let failure = await package.load(source: """
        function render(ctx)
            ctx.state.renders = (ctx.state.renders or 0) + 1
            return ui.box{
                w = ctx.state.renders * 100 + ctx.data.seconds,
                h = ctx.data.island and ctx.data.island.size.w or 1
            }
        end
        """)
        XCTAssertNil(failure)
        var data = ShellWidgetData()
        data.seconds = 1
        await package.receive(.update(data))
        await package.receive(.bars([bar: ShellBarData(), island: islandData(visible: true)]))
        let first = await package.islandRenderSnapshot(island)
        XCTAssertEqual(first?.sequence, 1)
        XCTAssertEqual(first?.width, 101)
        XCTAssertEqual(first?.height, 760)
        let barFirst = await package.islandRenderSnapshot(bar)
        XCTAssertEqual(barFirst?.height, 1)

        await package.receive(.bars([bar: ShellBarData(), island: islandData(visible: false)]))
        for seconds in 2 ... 4 {
            data.seconds = Double(seconds)
            await package.receive(.update(data))
        }
        let hidden = await package.islandRenderSnapshot(island)
        XCTAssertEqual(hidden?.sequence, 1)
        XCTAssertEqual(hidden?.width, 101)

        await package.receive(.bars([bar: ShellBarData(), island: islandData(visible: true)]))
        let resumed = await package.islandRenderSnapshot(island)
        XCTAssertEqual(resumed?.sequence, 2)
        XCTAssertEqual(resumed?.width, 204)
        await package.receive(.bars([bar: ShellBarData(), island: islandData(visible: true)]))
        await package.receive(.update(data))
        let unchanged = await package.islandRenderSnapshot(island)
        XCTAssertEqual(unchanged?.sequence, 2)
        await package.close()
    }

    func testInitiallyHiddenIslandCreatesStateWithoutRenderingUntilShown() async throws {
        let key = ShellBarKey(monitor: monitor().id, placement: .island)
        let package = ShellWidgetPackage(name: "hidden", generation: 1, outbox: ShellWidgetOutbox { _ in })
        let failure = await package.load(source: """
        function render(ctx)
            ctx.state.renders = (ctx.state.renders or 0) + 1
            return ui.box{ w = ctx.state.renders, h = ctx.data.island.visible and 10 or 20 }
        end
        """)
        XCTAssertNil(failure)
        await package.receive(.bars([key: islandData(visible: false)]))
        let hidden = await package.islandRenderSnapshot(key)
        XCTAssertEqual(hidden?.sequence, 0)
        XCTAssertNil(hidden?.width)

        await package.receive(.bars([key: islandData(visible: true)]))
        let shown = await package.islandRenderSnapshot(key)
        XCTAssertEqual(shown?.sequence, 1)
        XCTAssertEqual(shown?.width, 1)
        XCTAssertEqual(shown?.height, 10)
        await package.close()
    }

    private func islandData(visible: Bool) -> ShellBarData {
        let monitor = monitor()
        return ShellBarData(surface: ShellIslandData(
            monitor: monitor,
            geometry: ShellIslandGeometry(monitor: monitor, size: CGSize(width: 760, height: 300)),
            visible: visible,
            fullscreen: !visible
        ))
    }

    private func monitor() -> Monitor {
        Monitor(
            id: .init(displayId: 92110), displayId: 92110,
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 868),
            hasNotch: true, notchRange: 630 ... 810, notchHeight: 32, name: "Island"
        )
    }
}
