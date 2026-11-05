// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class MacOSFusionOffTests: XCTestCase {
    private final class EventRecorder: NSResponder {
        var dragged = 0
        var released = 0

        override func mouseDragged(with _: NSEvent) {
            dragged += 1
        }

        override func mouseUp(with _: NSEvent) {
            released += 1
        }
    }

    private func mouseEvent(_ type: NSEvent.EventType) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: NSPoint(x: 10, y: 10),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
    }

    func testATabRailPassesDragsAndReleasesOnWhenItTakesNoDrags() throws {
        for acceptsDrags in [false, true] {
            let view = TabRailView(frame: NSRect(x: 0, y: 0, width: 40, height: 200), motionPolicy: MotionPolicy())
            let recorder = EventRecorder()
            view.nextResponder = recorder
            view.acceptsDrags = { acceptsDrags }

            view.mouseDragged(with: try mouseEvent(.leftMouseDragged))
            view.mouseUp(with: try mouseEvent(.leftMouseUp))

            XCTAssertEqual(recorder.dragged, acceptsDrags ? 0 : 1, "\(acceptsDrags)")
            XCTAssertEqual(recorder.released, acceptsDrags ? 0 : 1, "\(acceptsDrags)")
        }
    }

    func testAnEngineThatNeverHadPeeksNeverSetsACap() {
        let engine = NiriLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        let frame = CGRect(x: 0, y: 0, width: 1_500, height: 900)
        let monitor = Monitor(
            id: Monitor.ID(displayId: 99), displayId: 99, frame: frame, visibleFrame: frame,
            hasNotch: false, name: "Fusion off"
        )
        engine.syncWorkspaceAssignments(
            [(workspaceId: workspaceId, monitor: monitor)],
            orientations: [monitor.id: .horizontal]
        )
        var previous: NiriWindow?
        for index in 0 ..< 4 {
            previous = engine.addWindow(
                token: WindowToken(pid: 991, windowId: index + 1),
                to: workspaceId,
                afterSelection: previous?.id
            )
        }

        engine.applyEdgePeekCaps(in: workspaceId, workingFrame: frame, gap: 12)

        XCTAssertFalse(engine.hasSetEdgePeekCaps)
        XCTAssertTrue(engine.columns(in: workspaceId).allSatisfy { $0.edgePeekCap == nil })

        engine.edgePeekShare = 0.05
        engine.applyEdgePeekCaps(in: workspaceId, workingFrame: frame, gap: 12)
        XCTAssertTrue(engine.hasSetEdgePeekCaps)
        XCTAssertTrue(engine.columns(in: workspaceId).contains { $0.edgePeekCap != nil })

        engine.edgePeekShare = nil
        engine.applyEdgePeekCaps(in: workspaceId, workingFrame: frame, gap: 12)
        XCTAssertTrue(engine.columns(in: workspaceId).allSatisfy { $0.edgePeekCap == nil })
    }
}
