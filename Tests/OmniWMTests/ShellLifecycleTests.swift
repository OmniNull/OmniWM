// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMScriptHost
import XCTest

private extension ShellWidgetPackage {
    func lifecycleWidth(_ key: ShellBarKey) -> Float? {
        guard let instance = script?.instances[key] else { return nil }
        var count = 0
        guard let bytes = omni_instance_output(instance, OMNI_VIEW_BAR, &count),
              count >= MemoryLayout<omni_wire_header>.stride + MemoryLayout<omni_wire_node>.stride
        else { return nil }
        return UnsafeRawPointer(bytes).loadUnaligned(
            fromByteOffset: MemoryLayout<omni_wire_header>.stride,
            as: omni_wire_node.self
        ).width
    }
}

@MainActor
final class ShellLifecycleTests: XCTestCase {
    func testHostLifecycleTargetsOnlyTheChangedDisplayAndIgnoresWorkspaceData() async {
        let package = ShellWidgetPackage(name: "lifecycle", generation: 1, outbox: ShellWidgetOutbox { batch in
            XCTAssertNil(batch["lifecycle"]?.failure)
        })
        let failure = await package.load(source: """
        function trigger(ctx, event)
            assert(event.source == 'host')
            if event.name == 'reloaded' then
                assert(ctx.state.count == nil)
                ctx.state.count = 1
            elseif event.name == 'displayChanged' then
                assert(ctx.state.count ~= nil)
                ctx.state.count += 1
            else
                error('unexpected lifecycle event')
            end
        end
        function render(ctx) return ui.box{w=ctx.state.count or 100,h=10} end
        """)
        XCTAssertNil(failure)
        let first = ShellBarKey(monitor: Monitor.ID(displayId: 94100))
        let second = ShellBarKey(monitor: Monitor.ID(displayId: 94101))
        var bars = [first: ShellBarData(), second: ShellBarData()]
        await package.receive(.bars(bars))
        var width = await package.lifecycleWidth(first)
        XCTAssertEqual(width, 1)
        width = await package.lifecycleWidth(second)
        XCTAssertEqual(width, 1)
        await package.receive(.bars(bars))
        bars[first]?.workspaces = [ShellBarWorkspace(id: "1", name: "Work", focused: true, windows: [])]
        await package.receive(.bars(bars))
        width = await package.lifecycleWidth(first)
        XCTAssertEqual(width, 1)
        bars[first]?.style.height = 30
        await package.receive(.bars(bars))
        width = await package.lifecycleWidth(first)
        XCTAssertEqual(width, 2)
        width = await package.lifecycleWidth(second)
        XCTAssertEqual(width, 1)
        bars.removeValue(forKey: first)
        await package.receive(.bars(bars))
        bars[first] = ShellBarData()
        await package.receive(.bars(bars))
        width = await package.lifecycleWidth(first)
        XCTAssertEqual(width, 1)
        await package.close()
    }
}
