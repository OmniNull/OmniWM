// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class OverviewViewInteractionTests: XCTestCase {
    private final class Recorder {
        var selected: [WindowHandle] = []
        var closed: [WindowHandle] = []
        var dismissals = 0
        var dragBegins: [(handle: WindowHandle, start: CGPoint)] = []
        var dragUpdates: [CGPoint] = []
        var dragEnds: [CGPoint] = []
        var workspaces: [WorkspaceDescriptor.ID] = []
        var pills: [OverviewOverflowPill] = []
    }

    private let cardFrame = CGRect(x: 100, y: 100, width: 200, height: 140)
    private let cardInterior = CGPoint(x: 200, y: 170)

    func testPressAndReleaseActivatesThePressedCardOnMouseUp() throws {
        let surface = try makeSurface()
        defer { surface.panel.close() }

        surface.view.mouseDown(with: try mouseEvent(.leftMouseDown, at: cardInterior, in: surface.panel))
        XCTAssertTrue(surface.recorder.selected.isEmpty)

        surface.view.mouseUp(with: try mouseEvent(.leftMouseUp, at: cardInterior, in: surface.panel))

        XCTAssertEqual(surface.recorder.selected, [surface.item.handle])
        XCTAssertTrue(surface.recorder.dragBegins.isEmpty)
        XCTAssertEqual(surface.recorder.dismissals, 0)
    }

    func testMovingPastThresholdDragsWithoutModifier() throws {
        let surface = try makeSurface()
        defer { surface.panel.close() }
        let moved = CGPoint(x: cardInterior.x + 4, y: cardInterior.y + 8)
        let released = CGPoint(x: 520, y: 400)

        surface.view.mouseDown(with: try mouseEvent(.leftMouseDown, at: cardInterior, in: surface.panel))
        surface.view.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: moved, in: surface.panel))
        surface.view.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: released, in: surface.panel))
        surface.view.mouseUp(with: try mouseEvent(.leftMouseUp, at: released, in: surface.panel))

        XCTAssertEqual(surface.recorder.dragBegins.count, 1)
        XCTAssertTrue(surface.recorder.dragBegins.first?.handle === surface.item.handle)
        XCTAssertEqual(surface.recorder.dragBegins.first?.start, cardInterior)
        XCTAssertEqual(surface.recorder.dragUpdates, [moved, released])
        XCTAssertEqual(surface.recorder.dragEnds, [released])
        XCTAssertTrue(surface.recorder.selected.isEmpty)
    }

    func testMovingUnderThresholdStillActivates() throws {
        let surface = try makeSurface()
        defer { surface.panel.close() }
        let jitter = CGPoint(x: cardInterior.x + 3, y: cardInterior.y + 2)

        surface.view.mouseDown(with: try mouseEvent(.leftMouseDown, at: cardInterior, in: surface.panel))
        surface.view.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: jitter, in: surface.panel))
        surface.view.mouseUp(with: try mouseEvent(.leftMouseUp, at: jitter, in: surface.panel))

        XCTAssertTrue(surface.recorder.dragBegins.isEmpty)
        XCTAssertTrue(surface.recorder.dragUpdates.isEmpty)
        XCTAssertEqual(surface.recorder.selected, [surface.item.handle])
    }

    func testOptionDragStillDrags() throws {
        let surface = try makeSurface()
        defer { surface.panel.close() }
        let moved = CGPoint(x: cardInterior.x + 10, y: cardInterior.y)

        surface.view.mouseDown(with: try mouseEvent(
            .leftMouseDown,
            at: cardInterior,
            modifiers: .option,
            in: surface.panel
        ))
        surface.view.mouseDragged(with: try mouseEvent(
            .leftMouseDragged,
            at: moved,
            modifiers: .option,
            in: surface.panel
        ))
        surface.view.mouseUp(with: try mouseEvent(.leftMouseUp, at: moved, modifiers: .option, in: surface.panel))

        XCTAssertEqual(surface.recorder.dragBegins.count, 1)
        XCTAssertEqual(surface.recorder.dragEnds, [moved])
        XCTAssertTrue(surface.recorder.selected.isEmpty)
    }

    func testCloseButtonClosesOnMouseDownWithoutArmingADrag() throws {
        let surface = try makeSurface()
        defer { surface.panel.close() }
        let size = OverviewRenderStyle.Metrics.closeButtonSize
        let padding = OverviewRenderStyle.Metrics.closeButtonPadding
        let closeButton = CGPoint(x: cardFrame.maxX - padding - size / 2, y: cardFrame.maxY - padding - size / 2)

        surface.view.mouseDown(with: try mouseEvent(.leftMouseDown, at: closeButton, in: surface.panel))
        XCTAssertEqual(surface.recorder.closed, [surface.item.handle])
        surface.view.mouseUp(with: try mouseEvent(.leftMouseUp, at: closeButton, in: surface.panel))

        XCTAssertEqual(surface.recorder.closed, [surface.item.handle])
        XCTAssertTrue(surface.recorder.selected.isEmpty)
        XCTAssertTrue(surface.recorder.dragBegins.isEmpty)
    }

    func testRibbonPressActivatesWorkspaceAndOverflowPillPages() throws {
        let surface = try makeSurface()
        defer { surface.panel.close() }
        var section = try XCTUnwrap(surface.view.layout.workspaceSections.first)
        section.ribbonFrame = CGRect(x: 20, y: 40, width: 760, height: 300)
        section.hiddenColumnsAfter = 2
        var layout = surface.view.layout
        layout.replaceWorkspaceSections([section])
        surface.view.updateLayout(layout, state: .open, searchQuery: "", selectedWindowHandle: nil)
        surface.view.updateLayer()

        let ribbonBackground = CGPoint(x: 600, y: 60)
        surface.view.mouseDown(with: try mouseEvent(.leftMouseDown, at: ribbonBackground, in: surface.panel))
        XCTAssertEqual(surface.recorder.workspaces, [section.workspaceId])
        XCTAssertEqual(surface.recorder.dismissals, 0)

        let pill = try XCTUnwrap(layout.overflowPills(for: section).first)
        surface.view.mouseDown(with: try mouseEvent(
            .leftMouseDown,
            at: CGPoint(x: pill.frame.midX, y: pill.frame.midY),
            in: surface.panel
        ))
        XCTAssertEqual(surface.recorder.pills, [pill])
        XCTAssertEqual(surface.recorder.workspaces.count, 1)
        XCTAssertTrue(surface.recorder.selected.isEmpty)
    }

    func testBackdropPressDismissesOnMouseDown() throws {
        let surface = try makeSurface()
        defer { surface.panel.close() }
        let backdrop = CGPoint(x: 700, y: 500)

        surface.view.mouseDown(with: try mouseEvent(.leftMouseDown, at: backdrop, in: surface.panel))
        XCTAssertEqual(surface.recorder.dismissals, 1)
        surface.view.mouseUp(with: try mouseEvent(.leftMouseUp, at: backdrop, in: surface.panel))

        XCTAssertEqual(surface.recorder.dismissals, 1)
        XCTAssertTrue(surface.recorder.selected.isEmpty)
    }

    func testClearSearchHasItsOwnHitTargetWithoutDismissal() throws {
        let surface = try makeSurface()
        defer { surface.panel.close() }
        var layout = surface.view.layout
        layout.searchBarFrame = CGRect(x: 200, y: 520, width: 400, height: 44)
        surface.view.updateLayout(layout, state: .open, searchQuery: "Missing", selectedWindowHandle: nil)
        var cleared = 0
        surface.view.onClearSearch = { cleared += 1 }
        let frame = layout.searchClearFrame
        surface.view.mouseDown(with: try mouseEvent(
            .leftMouseDown, at: CGPoint(x: frame.midX, y: frame.midY), in: surface.panel
        ))
        XCTAssertEqual(cleared, 1)
        XCTAssertEqual(surface.recorder.dismissals, 0)
        XCTAssertTrue(surface.recorder.selected.isEmpty)
    }

    func testMagnifyZoomsProxiesAroundPointerAndActivatesOnlyOnRelease() throws {
        let surface = try makeSurface()
        defer { surface.panel.close() }
        let renderer = surface.view.layerRenderer
        let card = try XCTUnwrap(renderer.windowLayers[surface.item.handle]?.root)
        let point = CGPoint(x: 140, y: 125)
        let original = card.convert(card.bounds, to: renderer.root)

        surface.view.magnify(with: MagnifyEvent(.began), at: point)
        surface.view.magnify(with: MagnifyEvent(.changed, delta: 0.6), at: point)
        let displayed = card.convert(card.bounds, to: renderer.root)
        XCTAssertEqual(displayed.width, original.width * 1.6, accuracy: 0.001)
        XCTAssertEqual(displayed.minX, point.x + (original.minX - point.x) * 1.6, accuracy: 0.001)
        XCTAssertEqual(displayed.minY, point.y + (original.minY - point.y) * 1.6, accuracy: 0.001)
        XCTAssertTrue(surface.recorder.selected.isEmpty)

        let outsideOriginalCard = CGPoint(x: original.maxX + 8, y: point.y)
        surface.view.magnify(with: MagnifyEvent(.ended), at: outsideOriginalCard)
        surface.view.magnify(with: MagnifyEvent(.ended), at: outsideOriginalCard)
        XCTAssertEqual(surface.recorder.selected, [surface.item.handle])
        XCTAssertTrue(surface.recorder.closed.isEmpty)
        XCTAssertEqual(surface.recorder.dismissals, 0)
    }

    func testPinchReleaseOutsideThePanelDoesNotActivateAClippedCard() throws {
        let surface = try makeSurface()
        defer { surface.panel.close() }
        let renderer = surface.view.layerRenderer
        let card = try XCTUnwrap(renderer.windowLayers[surface.item.handle]?.root)
        let anchor = CGPoint(x: 290, y: 160)
        let outside = CGPoint(x: -20, y: anchor.y)
        surface.view.updateLayout(
            surface.view.layout, state: .open, searchQuery: "", selectedWindowHandle: nil, animationsEnabled: false
        )

        surface.view.magnify(with: MagnifyEvent(.began, delta: 1), at: anchor)
        XCTAssertTrue(card.convert(card.bounds, to: renderer.root).contains(outside))
        surface.view.magnify(with: MagnifyEvent(.ended), at: outside)

        XCTAssertTrue(surface.recorder.selected.isEmpty)
        XCTAssertFalse(renderer.camera.isTracking)
    }

    func testLocalPinchMonitorKeepsThePanelUnderTheInitialPointer() throws {
        let surface = try makeSurface()
        defer { surface.panel.close() }
        let controller = WindowAdmissionTestSupport.controller(prefix: "OverviewPinchRouting")
        controller.motionPolicy.animationsEnabled = false
        let frames = [surface.view.frame, surface.view.frame.offsetBy(dx: surface.view.frame.width, dy: 0)]
        controller.workspaceManager.applyMonitorConfigurationChange(frames.enumerated().map { index, frame in
            let id = CGDirectDisplayID(93_031 + index)
            return Monitor(
                id: .init(displayId: id),
                displayId: id,
                frame: frame,
                visibleFrame: frame,
                hasNotch: false,
                name: "Pinch test \(index)"
            )
        })
        var pointer = CGPoint.zero
        controller.currentMouseLocation = { pointer }
        var monitorHandler: ((NSEvent) -> NSEvent?)?
        var environment = OverviewEnvironment()
        environment.frontmostApplicationPID = { nil }
        environment.addLocalEventMonitor = { mask, handler in
            if mask.contains(.magnify) { monitorHandler = handler }
            return nil
        }
        let registry = OwnedWindowRegistry(surfaceCoordinator: SurfaceCoordinator())
        let overview = OverviewController(
            wmController: controller, motionPolicy: controller.motionPolicy,
            environment: environment, ownedWindowRegistry: registry
        )
        XCTAssertTrue(overview.beginOpening())
        defer { overview.dismiss(animated: false) }
        let primary = try XCTUnwrap(overview.windowSession.primaryOverviewWindow())
        let panels = registry.visibleWindows(kind: .overview).compactMap { $0 as? OverviewWindow }
        let secondary = try XCTUnwrap(panels.first { $0 !== primary })
        let receive = try XCTUnwrap(monitorHandler, "Overview does not monitor magnification events")
        var selections: [Monitor.ID] = []
        for panel in panels {
            panel.updateLayout(
                surface.view.layout,
                state: .open,
                searchQuery: "",
                selectedWindowHandle: nil,
                animationsEnabled: false
            )
            panel.onWindowSelected = { monitorId, _ in selections.append(monitorId) }
        }
        let view = try XCTUnwrap(secondary.contentView?.subviews.compactMap { $0 as? OverviewView }.first)
        view.updateLayer()
        let camera = view.layerRenderer.camera
        let secondaryPoint = secondary.convertPoint(toScreen: view.convert(cardInterior, to: nil))
        let primaryPoint = primary.convertPoint(toScreen: cardInterior)
        XCTAssertTrue(secondary.frame.contains(secondaryPoint))
        XCTAssertFalse(primary.frame.contains(secondaryPoint))

        pointer = secondaryPoint
        XCTAssertNil(receive(MagnifyEvent(.began, at: primary.convertPoint(fromScreen: pointer), in: primary)))
        XCTAssertTrue(camera.isTracking)
        pointer = primaryPoint
        XCTAssertNil(receive(MagnifyEvent(.changed, at: cardInterior, delta: 0.8, in: primary)))
        XCTAssertEqual(camera.layer.transform.m11, 1.8, accuracy: 0.001)
        XCTAssertNil(receive(MagnifyEvent(.ended, at: cardInterior, in: primary)))
        XCTAssertTrue(selections.isEmpty)
        XCTAssertFalse(camera.isTracking)

        pointer = secondaryPoint
        let sourcePoint = primary.convertPoint(fromScreen: pointer)
        XCTAssertNil(receive(MagnifyEvent(.began, at: sourcePoint, delta: 0.8, in: primary)))
        XCTAssertNil(receive(MagnifyEvent(.ended, at: sourcePoint, in: primary)))
        XCTAssertEqual(selections, [secondary.monitorId])
    }

    func testSmallCancelledAndBackdropPinchesLeaveGridInteractive() throws {
        let surface = try makeSurface()
        defer { surface.panel.close() }
        surface.view.updateLayout(
            surface.view.layout,
            state: .open,
            searchQuery: "",
            selectedWindowHandle: nil,
            animationsEnabled: false
        )
        let renderer = surface.view.layerRenderer
        let card = try XCTUnwrap(renderer.windowLayers[surface.item.handle]?.root)
        let original = card.convert(card.bounds, to: renderer.root)
        let backdrop = CGPoint(x: 750, y: 40)
        for (start, delta, phase): (CGPoint, CGFloat, NSEvent.Phase) in [
            (cardInterior, 0.2, .ended), (cardInterior, 0.8, .cancelled), (backdrop, 0.8, .ended)
        ] {
            surface.view.magnify(with: MagnifyEvent(.began), at: start)
            surface.view.magnify(with: MagnifyEvent(.changed, delta: delta), at: start)
            surface.view.magnify(with: MagnifyEvent(phase), at: cardInterior)
            XCTAssertEqual(card.convert(card.bounds, to: renderer.root), original)
            XCTAssertTrue(surface.recorder.selected.isEmpty)
        }
        surface.view.mouseDown(with: try mouseEvent(.leftMouseDown, at: cardInterior, in: surface.panel))
        surface.view.mouseUp(with: try mouseEvent(.leftMouseUp, at: cardInterior, in: surface.panel))
        XCTAssertEqual(surface.recorder.selected, [surface.item.handle])
    }

    func testRegrabbingReturningCameraKeepsPreviewPointUnderNewAnchor() throws {
        let surface = try makeSurface()
        defer { surface.panel.close() }
        let renderer = surface.view.layerRenderer
        let card = try XCTUnwrap(renderer.windowLayers[surface.item.handle]?.root)
        let nextAnchor = CGPoint(x: cardInterior.x + 36, y: cardInterior.y)
        renderer.camera.layer.speed = 0
        surface.view.magnify(with: MagnifyEvent(.began, delta: 0.4), at: cardInterior)
        let localPoint = card.convert(nextAnchor, from: renderer.root)
        surface.view.magnify(with: MagnifyEvent(.ended), at: cardInterior)
        surface.view.magnify(with: MagnifyEvent(.began, delta: 0.1), at: nextAnchor)
        let projected = card.convert(localPoint, to: renderer.root)
        XCTAssertEqual(projected.x, nextAnchor.x, accuracy: 0.001)
        XCTAssertEqual(projected.y, nextAnchor.y, accuracy: 0.001)

        surface.view.magnify(with: MagnifyEvent(.changed, delta: -0.9), at: nextAnchor)
        let restored = card.convert(card.bounds, to: renderer.root)
        let rounding = CGFloat.rounding(operations: 8, at: cardFrame.maxX)
        XCTAssertEqual(restored.minX, cardFrame.minX, accuracy: rounding)
        XCTAssertEqual(restored.minY, cardFrame.minY, accuracy: rounding)
        XCTAssertEqual(restored.width, cardFrame.width, accuracy: rounding)
        XCTAssertEqual(restored.height, cardFrame.height, accuracy: rounding)
    }

    func testInterruptedPinchCannotActivateOnLateRelease() throws {
        let surface = try makeSurface()
        defer { surface.panel.close() }
        let layout = surface.view.layout
        surface.view.magnify(with: MagnifyEvent(.began, delta: 0.7), at: cardInterior)
        surface.view.updateLayout(.init(), state: .open, searchQuery: "", selectedWindowHandle: nil)
        surface.view.updateLayout(layout, state: .open, searchQuery: "", selectedWindowHandle: nil)
        surface.view.magnify(with: MagnifyEvent(.ended), at: cardInterior)
        XCTAssertTrue(surface.recorder.selected.isEmpty)

        surface.view.magnify(with: MagnifyEvent(.began, delta: 0.7), at: cardInterior)
        surface.view.updateLayout(
            layout,
            state: .closing(targetWindow: nil),
            searchQuery: "",
            selectedWindowHandle: nil
        )
        surface.view.magnify(with: MagnifyEvent(.began, delta: 0.7), at: cardInterior)
        surface.view.updateLayout(layout, state: .open, searchQuery: "", selectedWindowHandle: nil)
        surface.view.magnify(with: MagnifyEvent(.ended), at: cardInterior)
        XCTAssertTrue(surface.recorder.selected.isEmpty)
    }

    func testMagnificationAndCardPressDoNotTakeOverEachOther() throws {
        let surface = try makeSurface()
        defer { surface.panel.close() }
        surface.view.mouseDown(with: try mouseEvent(.leftMouseDown, at: cardInterior, in: surface.panel))
        surface.view.magnify(with: MagnifyEvent(.began, delta: 0.7), at: cardInterior)
        surface.view.magnify(with: MagnifyEvent(.ended), at: cardInterior)
        XCTAssertTrue(surface.recorder.selected.isEmpty)
        surface.view.mouseUp(with: try mouseEvent(.leftMouseUp, at: cardInterior, in: surface.panel))
        XCTAssertEqual(surface.recorder.selected, [surface.item.handle])

        let backdrop = CGPoint(x: 750, y: 40)
        surface.view.magnify(with: MagnifyEvent(.began, delta: 0.7), at: cardInterior)
        surface.view.mouseDown(with: try mouseEvent(.leftMouseDown, at: backdrop, in: surface.panel))
        surface.view.magnify(with: MagnifyEvent(.ended), at: backdrop)
        XCTAssertEqual(surface.recorder.selected, [surface.item.handle])
        XCTAssertEqual(surface.recorder.dismissals, 0)
    }

    private struct Surface {
        let view: OverviewView
        let panel: NSPanel
        let item: OverviewWindowItem
        let recorder: Recorder
    }

    private func makeSurface() throws -> Surface {
        let workspaceId = UUID()
        let item = OverviewWindowItem(
            handle: WindowHandle(id: WindowToken(pid: 1, windowId: 1)),
            windowId: 1,
            workspaceId: workspaceId,
            title: "Window",
            appName: "App",
            appIcon: nil,
            originalFrame: CGRect(x: 50, y: 50, width: 600, height: 400),
            overviewFrame: cardFrame,
            matchesSearch: true
        )
        let section = OverviewWorkspaceSection(
            workspaceId: workspaceId,
            name: "Workspace",
            windows: [item],
            sectionFrame: cardFrame,
            labelFrame: .zero,
            gridFrame: cardFrame,
            isActive: true
        )
        var layout = OverviewLayout()
        layout.replaceWorkspaceSections([section])

        let view = OverviewView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let panel = NSPanel(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = view
        let recorder = Recorder()
        view.onWindowSelected = { recorder.selected.append($0) }
        view.onWindowClosed = { recorder.closed.append($0) }
        view.onDismiss = { recorder.dismissals += 1 }
        view.onWorkspaceSelected = { recorder.workspaces.append($0) }
        view.onOverflowPillPressed = { recorder.pills.append($0) }
        view.onDragBegin = { recorder.dragBegins.append((handle: $0, start: $1)) }
        view.onDragUpdate = { recorder.dragUpdates.append($0) }
        view.onDragEnd = { recorder.dragEnds.append($0) }
        view.updateLayout(layout, state: .open, searchQuery: "", selectedWindowHandle: nil)
        view.updateLayer()
        return Surface(view: view, panel: panel, item: item, recorder: recorder)
    }

    private func mouseEvent(
        _ type: NSEvent.EventType,
        at location: CGPoint,
        modifiers: NSEvent.ModifierFlags = [],
        in window: NSWindow
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: modifiers,
            timestamp: 1,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
    }
}

private final class MagnifyEvent: NSEvent, @unchecked Sendable {
    private let gesturePhase: Phase
    private let point: CGPoint
    private let delta: CGFloat
    private let sourceWindow: NSWindow?

    init(_ phase: Phase, at point: CGPoint = .zero, delta: CGFloat = 0, in sourceWindow: NSWindow? = nil) {
        gesturePhase = phase
        self.point = point
        self.delta = delta
        self.sourceWindow = sourceWindow
        super.init()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var type: EventType {
        .magnify
    }

    override var phase: Phase {
        gesturePhase
    }

    override var locationInWindow: CGPoint {
        point
    }

    override var window: NSWindow? {
        sourceWindow
    }

    override var magnification: CGFloat {
        delta
    }
}
