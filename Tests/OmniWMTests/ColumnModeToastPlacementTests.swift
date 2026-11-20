// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import CoreGraphics
@testable import OmniWM
import XCTest

@MainActor
final class ColumnModeToastPlacementTests: XCTestCase {
    private let size = CGSize(width: 140, height: 30)
    private let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)

    func testCentersBelowColumnTop() {
        let column = CGRect(x: 200, y: 100, width: 400, height: 600)
        let frame = ColumnModeToastController.pillFrame(size: size, columnFrame: column, visibleFrame: visible)
        XCTAssertEqual(frame.midX, column.midX)
        XCTAssertEqual(frame.maxY, column.maxY - ColumnModeToastController.topInset)
    }

    func testClampsIntoVisibleFrame() {
        let offLeft = CGRect(x: -380, y: 100, width: 400, height: 600)
        let offRight = CGRect(x: 980, y: 100, width: 400, height: 600)
        XCTAssertEqual(
            ColumnModeToastController.pillFrame(size: size, columnFrame: offLeft, visibleFrame: visible).minX,
            0
        )
        XCTAssertEqual(
            ColumnModeToastController.pillFrame(size: size, columnFrame: offRight, visibleFrame: visible).maxX,
            1000
        )
    }
}

@MainActor
final class ColumnModeToastLifecycleTests: XCTestCase {
    private let column = CGRect(x: 200, y: 100, width: 400, height: 600)
    private let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)

    func testAMessageFollowingAColumnStaysOnTheDisplayAtTheSameSize() throws {
        let registry = OwnedWindowRegistry(surfaceCoordinator: SurfaceCoordinator())
        let toast = ColumnModeToastController(ownedWindowRegistry: registry, sleep: { _ in })
        defer { toast.destroy() }
        let source = ColumnModeToastController.Source(workspaceId: UUID(), monitorId: Monitor.ID(displayId: 1))
        toast.show(
            .columnMode(isTabbed: true),
            columnFrame: column,
            visibleFrame: visible,
            motion: .disabled,
            source: source
        )
        let panel = try XCTUnwrap(registry.visibleWindows(kind: .columnModeToast).first as? NSPanel)
        let size = panel.frame.size

        toast.move(columnFrame: column.offsetBy(dx: visible.maxX - column.minX - 20, dy: 0), visibleFrame: visible)

        XCTAssertEqual(panel.frame.size, size)
        XCTAssertLessThanOrEqual(panel.frame.maxX, visible.maxX + 0.5)
        XCTAssertGreaterThanOrEqual(panel.frame.minX, visible.minX - 0.5)
    }

    func testDismissesWhenDisplayTimerFires() async throws {
        let sleeper = ColumnModeToastManualSleeper()
        let registry = OwnedWindowRegistry(surfaceCoordinator: SurfaceCoordinator())
        let toast = ColumnModeToastController(
            ownedWindowRegistry: registry,
            sleep: { try await sleeper.sleep(for: $0) }
        )
        defer {
            toast.destroy()
            sleeper.resumeAll()
        }
        let source = ColumnModeToastController.Source(workspaceId: UUID(), monitorId: Monitor.ID(displayId: 1))
        toast.show(
            .columnMode(isTabbed: true),
            columnFrame: column,
            visibleFrame: visible,
            motion: .disabled,
            source: source
        )
        let panel = try XCTUnwrap(registry.visibleWindows(kind: .columnModeToast).first as? NSPanel)
        let dismissalTask = try XCTUnwrap(toast.dismissalTask)
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(toast.source, source)
        XCTAssertTrue(registry.visibleWindows(kind: .utility).isEmpty)

        sleeper.resumeNext()
        await dismissalTask.value

        XCTAssertFalse(panel.isVisible)
        XCTAssertNil(toast.source)
    }

    func testOldFadeCompletionKeepsReplacementVisible() async throws {
        let sleeper = ColumnModeToastManualSleeper()
        let registry = OwnedWindowRegistry(surfaceCoordinator: SurfaceCoordinator())
        let toast = ColumnModeToastController(
            ownedWindowRegistry: registry,
            sleep: { try await sleeper.sleep(for: $0) }
        )
        defer {
            toast.destroy()
            sleeper.resumeAll()
        }
        let firstSource = ColumnModeToastController.Source(workspaceId: UUID(), monitorId: Monitor.ID(displayId: 1))
        let secondSource = ColumnModeToastController.Source(workspaceId: UUID(), monitorId: Monitor.ID(displayId: 1))
        toast.show(
            .columnMode(isTabbed: true),
            columnFrame: column,
            visibleFrame: visible,
            motion: .enabled,
            source: firstSource
        )
        let firstGeneration = toast.generation
        let firstDismissalTask = try XCTUnwrap(toast.dismissalTask)
        sleeper.resumeNext()
        await firstDismissalTask.value

        toast.show(
            .columnMode(isTabbed: false),
            columnFrame: column,
            visibleFrame: visible,
            motion: .enabled,
            source: secondSource
        )
        let replacementPanel = try XCTUnwrap(registry.visibleWindows(kind: .columnModeToast).first as? NSPanel)
        toast.finishFade(generation: firstGeneration)

        XCTAssertTrue(replacementPanel.isVisible)
        XCTAssertGreaterThan(replacementPanel.alphaValue, 0.99)
        XCTAssertEqual(toast.source, secondSource)

        toast.finishFade(generation: toast.generation)
        XCTAssertFalse(replacementPanel.isVisible)
        XCTAssertNil(toast.source)
    }

    func testHidesWhenSourceDisplayChangesWorkspace() throws {
        let controller = WindowAdmissionTestSupport.controller(prefix: "ColumnModeToastLifecycleTests")
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let monitor = Monitor(
            id: .init(displayId: 1),
            displayId: 1,
            frame: frame,
            visibleFrame: frame,
            hasNotch: false,
            name: "Toast"
        )
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        let sourceWorkspace = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let destination = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "2", createIfMissing: true))
        XCTAssertTrue(controller.workspaceManager.setActiveWorkspace(sourceWorkspace, on: monitor.id))

        let toast = controller.columnModeToast
        defer { toast.destroy() }
        let source = ColumnModeToastController.Source(workspaceId: sourceWorkspace, monitorId: monitor.id)
        toast.show(
            .columnMode(isTabbed: true),
            columnFrame: column,
            visibleFrame: visible,
            motion: .disabled,
            source: source
        )
        let panel = try XCTUnwrap(controller.ownedWindowRegistry.visibleWindows(kind: .columnModeToast)
            .first as? NSPanel)
        XCTAssertTrue(panel.isVisible)

        controller.handleSessionStateChanged(surfaceScope: .full)
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(toast.source, source)

        XCTAssertTrue(controller.workspaceManager.setActiveWorkspace(destination, on: monitor.id))
        XCTAssertFalse(panel.isVisible)
        XCTAssertNil(toast.source)
    }
}

@MainActor
private final class ColumnModeToastManualSleeper {
    private var permits = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func sleep(for _: Duration) async throws {
        try Task.checkCancellation()
        if permits > 0 {
            permits -= 1
        } else {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
        try Task.checkCancellation()
    }

    func resumeNext() {
        if waiters.isEmpty {
            permits += 1
        } else {
            waiters.removeFirst().resume()
        }
    }

    func resumeAll() {
        for waiter in waiters {
            waiter.resume()
        }
        waiters.removeAll()
    }
}
