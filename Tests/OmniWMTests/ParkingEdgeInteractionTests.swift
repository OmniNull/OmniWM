// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class ParkingEdgeInteractionTests: XCTestCase {
    @MainActor private final class Pointer {
        var value: CGPoint

        init(_ value: CGPoint = CGPoint(x: 91_000.5, y: 92_400)) {
            self.value = value
        }
    }

    @MainActor private final class Dwell {
        var durations: [Duration] = []
        var continuations: [CheckedContinuation<Void, Error>] = []
        var onStart: (() -> Void)?

        func sleep(_ duration: Duration) async throws {
            durations.append(duration)
            try await withCheckedThrowingContinuation { continuation in
                continuations.append(continuation)
                onStart?()
            }
        }

        func complete() {
            continuations.removeFirst().resume()
        }
    }

    @MainActor private final class Fixture {
        let key = ParkingEdgeMaskKey(monitorId: .init(displayId: 989_001), side: .left)
        let frame = CGRect(x: 91_000, y: 92_000, width: 1, height: 800)
        let workspaceId = WorkspaceDescriptor.ID()
        private let location = Pointer()
        var pointer: CGPoint {
            get { location.value }
            set { location.value = newValue }
        }

        let dwell = Dwell()
        var activations = 0
        var allowed = true
        let manager: ParkingEdgeMaskManager

        init() {
            let dwell = dwell
            let location = location
            manager = ParkingEdgeMaskManager(
                pointerLocation: { location.value }, sleep: { try await dwell.sleep($0) }
            )
            manager.animationsEnabled = { false }
        }

        static func make(hover: Bool) throws -> Fixture {
            let fixture = Fixture()
            fixture.manager.onActivate = { [weak fixture] _, _ in fixture?.activations += 1 }
            fixture.manager.canInteract = { [weak fixture] _ in fixture?.allowed == true }
            fixture.manager.apply([fixture.mask(hover: hover)])
            return fixture
        }

        func mask(hover: Bool, target: Int = 1) -> DesiredParkingEdgeMask {
            DesiredParkingEdgeMask(
                key: key,
                frame: frame,
                navigation: ParkingEdgeNavigation(
                    workspaceId: workspaceId, target: .init(pid: 989_001, windowId: target),
                    hoverEnabled: hover
                )
            )
        }

        func window() throws -> ParkingEdgeMaskWindow {
            try XCTUnwrap(SurfaceCoordinator.shared.visibleSurfaceInfos().first {
                $0.id == "parking-edge-mask-989001-left"
            }?.window as? ParkingEdgeMaskWindow)
        }
    }

    func testFinPlacementIsClampedAndMirroredOnEveryEdge() {
        let bounds = CGRect(x: -1200, y: 100, width: 1200, height: 900)
        for side in [ParkingEdgeMaskKey.Side.left, .right, .top, .bottom] {
            let mask = side.frame(in: bounds)
            for pointer in [bounds.origin, bounds.center, CGPoint(x: bounds.maxX, y: bounds.maxY)] {
                let fin = ParkingEdgeFinWindow.frame(at: pointer, maskFrame: mask, side: side)
                XCTAssertTrue(bounds.contains(fin))
                if side == .left || side == .right {
                    XCTAssertEqual(fin.width, 30)
                    XCTAssertEqual(fin.height, 108)
                } else {
                    XCTAssertEqual(fin.width, 108)
                    XCTAssertEqual(fin.height, 30)
                }
            }
        }
    }

    func testMaskBlocksFallbackHoverTargetingWithoutTakingKeyboardFocus() throws {
        let fixture = try Fixture.make(hover: false)
        defer { fixture.manager.removeAll() }
        let window = try fixture.window()
        XCTAssertFalse(window.ignoresMouseEvents)
        XCTAssertFalse(window.canBecomeKey)
        XCTAssertFalse(window.canBecomeMain)
        XCTAssertTrue(SurfaceCoordinator.shared.containsInteractive(point: fixture.pointer))
    }

    func testClickActivatesImmediatelyWithHoverDisabled() throws {
        let fixture = try Fixture.make(hover: false)
        defer { fixture.manager.removeAll() }
        let window = try fixture.window()
        let click = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: CGPoint(x: 0.5, y: 400), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
        ))
        window.contentView?.mouseDown(with: click)
        XCTAssertEqual(fixture.activations, 1)
        XCTAssertNil(window.dwellTask)
    }

    func testVerticalMaskHoverAndClickUseCocoaPointerBoundaries() throws {
        let bounds = CGRect(x: 91_000, y: 92_000, width: 1200, height: 800)
        for side in [ParkingEdgeMaskKey.Side.top, .bottom] {
            let frame = side.frame(in: bounds)
            let pointer = Pointer(CGPoint(x: frame.midX, y: frame.minY))
            var activations = 0
            let window = ParkingEdgeMaskWindow(
                key: .init(monitorId: .init(displayId: 989_002), side: side),
                pointerLocation: { pointer.value }, sleep: { _ in }, canInteract: { _ in true },
                animationsEnabled: { false }, onActivate: { _ in activations += 1 }
            )
            defer { window.destroy() }
            window.apply(DesiredParkingEdgeMask(
                key: .init(monitorId: .init(displayId: 989_002), side: side), frame: frame,
                navigation: .init(
                    workspaceId: .init(), target: .init(pid: 989_002, windowId: 1), hoverEnabled: false
                )
            ))
            let click = try XCTUnwrap(NSEvent.mouseEvent(
                with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
            ))
            window.updateHover()
            window.contentView?.mouseDown(with: click)
            XCTAssertEqual(activations, 0)
            XCTAssertFalse(SurfaceCoordinator.shared.containsInteractive(point: pointer.value))
            pointer.value.y = frame.maxY
            window.updateHover()
            XCTAssertTrue(SurfaceCoordinator.shared.containsInteractive(point: pointer.value))
            XCTAssertFalse(SurfaceCoordinator.shared.containsInteractive(
                point: pointer.value, excluding: .parkingEdgeMask
            ))
            XCTAssertTrue(SurfaceCoordinator.shared.visibleSurfaceIDs(kind: .parkingEdgeMask).contains(
                "parking-edge-fin-989002-\(side.rawValue)"
            ))
            window.contentView?.mouseDown(with: click)
            XCTAssertEqual(activations, 1)
        }
    }

    func testFinRevealReadsCurrentAnimationPolicyWithoutReapplyingMask() throws {
        let fixture = try Fixture.make(hover: false)
        defer { fixture.manager.removeAll() }
        let policy = MotionPolicy(animationsEnabled: true)
        fixture.manager.animationsEnabled = { policy.animationsEnabled }
        let window = try fixture.window()
        window.updateHover()
        let fin = try XCTUnwrap(SurfaceCoordinator.shared.visibleSurfaceInfos().first {
            $0.id == "parking-edge-fin-989001-left"
        }?.window)
        XCTAssertNotNil(fin.contentView?.layer?.animation(forKey: "parkingEdge.reveal"))
        fixture.pointer.x -= 40
        window.updateHover()
        policy.systemReducesMotion = true
        fixture.pointer.x += 40
        window.updateHover()
        XCTAssertTrue(fin.isVisible)
        XCTAssertNil(fin.contentView?.layer?.animation(forKey: "parkingEdge.reveal"))
    }

    func testDwellWaitsForOnePointFiveSecondsAndRequiresLeavingBeforeAnotherActivation() async throws {
        let fixture = try Fixture.make(hover: true)
        defer { fixture.manager.removeAll() }
        let window = try fixture.window()
        let started = expectation(description: "Dwell armed")
        fixture.dwell.onStart = { started.fulfill() }
        window.updateHover()
        let firstTask = try XCTUnwrap(window.dwellTask)
        await fulfillment(of: [started])
        XCTAssertEqual(fixture.activations, 0)
        XCTAssertEqual(fixture.dwell.durations, [.milliseconds(1500)])

        fixture.dwell.complete()
        await firstTask.value
        XCTAssertEqual(fixture.activations, 1)
        window.updateHover()
        XCTAssertNil(window.dwellTask)
        XCTAssertEqual(fixture.dwell.durations.count, 1)

        fixture.pointer.x -= 40
        window.updateHover()
        fixture.pointer.x += 40
        let reentered = expectation(description: "New entry armed")
        fixture.dwell.onStart = { reentered.fulfill() }
        window.updateHover()
        let secondTask = try XCTUnwrap(window.dwellTask)
        await fulfillment(of: [reentered])
        fixture.dwell.complete()
        await secondTask.value
        XCTAssertEqual(fixture.activations, 2)
    }

    func testLeavingOrRemovingMaskCancelsPendingDwell() async throws {
        for remove in [false, true] {
            let fixture = try Fixture.make(hover: true)
            let window = try fixture.window()
            let started = expectation(description: "Dwell armed")
            fixture.dwell.onStart = { started.fulfill() }
            window.updateHover()
            let task = try XCTUnwrap(window.dwellTask)
            await fulfillment(of: [started])
            if remove {
                fixture.manager.removeAll()
            } else {
                fixture.pointer.x -= 40
                window.updateHover()
            }
            fixture.dwell.complete()
            await task.value
            XCTAssertEqual(fixture.activations, 0)
            XCTAssertNil(window.dwellTask)
            fixture.manager.removeAll()
        }
    }

    func testChangedTargetOrBlockedInputCannotActivateAfterDwell() async throws {
        for changeTarget in [false, true] {
            let fixture = try Fixture.make(hover: true)
            defer { fixture.manager.removeAll() }
            let window = try fixture.window()
            let started = expectation(description: "Dwell armed")
            fixture.dwell.onStart = { started.fulfill() }
            window.updateHover()
            let task = try XCTUnwrap(window.dwellTask)
            await fulfillment(of: [started])
            if changeTarget {
                fixture.manager.apply([fixture.mask(hover: true, target: 2)])
            } else {
                fixture.allowed = false
            }
            fixture.dwell.complete()
            await task.value
            XCTAssertEqual(fixture.activations, 0)
            XCTAssertNil(window.dwellTask)
        }
    }

    func testMovingIntoTransparentFinCornerCancelsContinuousHover() async throws {
        let fixture = try Fixture.make(hover: true)
        defer { fixture.manager.removeAll() }
        let window = try fixture.window()
        let started = expectation(description: "Dwell armed")
        fixture.dwell.onStart = { started.fulfill() }
        window.updateHover()
        let task = try XCTUnwrap(window.dwellTask)
        await fulfillment(of: [started])
        let fin = try XCTUnwrap(SurfaceCoordinator.shared.visibleSurfaceInfos().first {
            $0.id == "parking-edge-fin-989001-left"
        }?.window as? ParkingEdgeFinWindow)
        fixture.pointer = CGPoint(x: fin.frame.maxX - 1, y: fin.frame.minY + 1)
        XCTAssertTrue(fin.frame.contains(fixture.pointer))
        XCTAssertFalse(fin.contains(fixture.pointer))
        let move = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved, location: CGPoint(x: 29, y: 1), modifierFlags: [], timestamp: 0,
            windowNumber: fin.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0
        ))
        fin.contentView?.mouseMoved(with: move)
        XCTAssertNil(window.dwellTask)
        XCTAssertFalse(fin.isVisible)
        fixture.pointer = CGPoint(x: fixture.frame.minX + 0.5, y: fixture.frame.midY)
        let reentered = expectation(description: "New entry armed")
        fixture.dwell.onStart = { reentered.fulfill() }
        window.updateHover()
        let newTask = try XCTUnwrap(window.dwellTask)
        await fulfillment(of: [reentered])
        fixture.dwell.complete()
        await task.value
        XCTAssertNotNil(window.dwellTask)
        XCTAssertTrue(fin.isVisible)
        XCTAssertEqual(fixture.activations, 0)
        fixture.dwell.complete()
        await newTask.value
        XCTAssertEqual(fixture.activations, 1)
    }
}
