// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import XCTest

final class ShellFrameTraceTests: XCTestCase {
    func testRecorderIsCaptureOnlyBoundedAndRejectsPreviousCaptureContexts() throws {
        let recorder = ShellFrameTraceRecorder(capacity: 2)
        XCTAssertNil(recorder.makeContext())
        XCTAssertFalse(recorder.isStoragePrepared)
        XCTAssertEqual(recorder.dump(), "none")

        recorder.beginCapture()
        let first = try XCTUnwrap(recorder.makeContext())
        recorder.record(.input, context: first)
        recorder.record(.enqueue, context: first)
        recorder.record(.handlerStart, context: first)
        let captured = recorder.dump()
        XCTAssertTrue(captured.contains("incomplete=true evicted=1"))
        XCTAssertFalse(captured.contains("event=input"))
        XCTAssertTrue(captured.contains("event=enqueue"))
        recorder.endCapture()
        recorder.record(.handlerEnd, context: first)
        XCTAssertEqual(recorder.dump(), captured)
        recorder.releaseStorage()
        XCTAssertFalse(recorder.isStoragePrepared)
        XCTAssertEqual(recorder.dump(), "none")

        recorder.beginCapture()
        let second = try XCTUnwrap(recorder.makeContext(parent: first))
        XCTAssertNotEqual(first.capture, second.capture)
        XCTAssertEqual(second.parent, 0)
        recorder.record(.input, context: first)
        XCTAssertEqual(recorder.dump(), "none")
        recorder.record(.input, context: second)
        XCTAssertTrue(recorder.dump().contains("capture=\(second.capture)"))
        recorder.endCapture()
    }

    func testFrameEstimatesRespectDisplayCommitTimeAndPendingCapacity() throws {
        let recorder = ShellFrameTraceRecorder(capacity: 16, pendingLimit: 2)
        recorder.beginCapture()
        var first = try XCTUnwrap(recorder.makeContext())
        first.display = 7
        var second = try XCTUnwrap(recorder.makeContext())
        second.display = 8
        recorder.commit(first, time: 10)
        recorder.commit(second, time: 9)
        recorder.commit(first, time: 10.5)
        XCTAssertEqual(recorder.pendingCount, 2)
        recorder.estimate(display: 7, targetTimestamp: 9.5)
        XCTAssertEqual(recorder.pendingCount, 2)
        recorder.estimate(display: 7, targetTimestamp: 11)
        XCTAssertEqual(recorder.pendingCount, 1)
        recorder.estimate(display: 7, targetTimestamp: 12)
        let output = recorder.dump()
        XCTAssertEqual(output.components(separatedBy: "event=frameEstimate").count - 1, 1)
        XCTAssertTrue(output.contains("incomplete_estimates=true dropped=1"))
        XCTAssertTrue(output.contains("estimated_target_t=11.000000000"))
        XCTAssertTrue(output.contains("estimate_only=true"))
        recorder.endCapture()
        XCTAssertEqual(recorder.pendingCount, 0)
        recorder.beginCapture()
        XCTAssertEqual(recorder.dump(), "none")
        recorder.endCapture()
    }

    @MainActor
    func testInactiveCaptureDoesNotInstallDisplayLinks() {
        ShellFrameTrace.shared.endCapture()
        ShellFrameTraceDisplayLink.stop()
        ShellFrameTraceDisplayLink.prepare(screen: NSScreen.main)
        XCTAssertEqual(ShellFrameTraceDisplayLink.count, 0)
    }

    @MainActor
    func testScriptedRenderAndHandlerKeepCorrelationAndMeasureCPU() async throws {
        ShellFrameTrace.shared.beginCapture()
        defer {
            ShellFrameTrace.shared.endCapture()
            ShellFrameTrace.shared.releaseStorage()
            ShellFrameTraceDisplayLink.stop()
        }
        let key = ShellBarKey(monitor: Monitor.ID(displayId: 42))
        var delivered: ShellWidgetDelivery.Tree?
        let outbox = ShellWidgetOutbox { batch in
            delivered = batch["trace-test"]?.trees[ShellTreeKey(bar: key, view: .bar)]
        }
        let package = ShellWidgetPackage(name: "trace-test", generation: 1, outbox: outbox)
        let failure = await package.load(source: """
        function render(ctx)
            return ui.box{ w = ctx.state.width or 10, h = 10,
                onClick = function(ctx) ctx.state.width = 20 end }
        end
        """)
        XCTAssertNil(failure)
        await package.receive(.bars([key: ShellBarData()]))
        await until { delivered != nil }
        let first = try XCTUnwrap(delivered)
        let node = first.nodes.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: MemoryLayout<omni_wire_header>.stride, as: omni_wire_node.self)
        }
        let input = try XCTUnwrap(ShellFrameTrace.shared.makeContext())
        await package.receive(.invoke(
            key,
            .bar,
            action: node.action,
            sequence: first.sequence,
            event: ShellEvent(trace: input)
        ))
        await until { delivered?.sequence == first.sequence + 1 }
        XCTAssertEqual(delivered?.trace?.parent, input.id)
        let output = ShellFrameTrace.shared.dump()
        let renders = output.split(separator: "\n").filter { $0.hasPrefix("event=render ") }
        let roots = renders.filter { $0.contains(" kind=\(OMNI_RENDER_ROOT.rawValue) ") }
        let assemblies = renders.filter { $0.contains(" kind=\(OMNI_RENDER_ASSEMBLE.rawValue) ") }
        let discovery = renders.filter { $0.contains(" kind=\(OMNI_RENDER_ACTIVITY.rawValue) ") }
        XCTAssertEqual(roots.count, 2)
        XCTAssertEqual(assemblies.count, 2)
        XCTAssertEqual(discovery.count, 1)
        XCTAssertEqual(renders.count, roots.count + assemblies.count + discovery.count)
        XCTAssertTrue(renders.allSatisfy { $0.contains("widget=trace-test") && !$0.contains("vm_bytes=0 ") })
        XCTAssertTrue(roots.allSatisfy { !$0.contains("encode_cpu_ns=0 ") && $0.contains(" count=1 ") })
        XCTAssertTrue(assemblies.allSatisfy { $0.contains(" count=0 ") })
        XCTAssertTrue(output.contains("event=handlerStart capture=\(input.capture) id=\(input.id)"))
        XCTAssertTrue(output.contains("event=handlerEnd capture=\(input.capture) id=\(input.id)"))
        XCTAssertEqual(output.components(separatedBy: "event=outboxDrain").count - 1, 2)
        XCTAssertEqual(output.components(separatedBy: "event=packageWake").count - 1, 2)
        await package.close()
    }
}
