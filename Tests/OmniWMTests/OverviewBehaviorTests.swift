// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Carbon
@testable import OmniWM
import XCTest

@MainActor
private final class OverviewAnimationTestClock {
    var time: CFTimeInterval = 0
}

@MainActor
private final class OverviewPostCloseHandoffScheduler {
    private(set) var handoffs: [@MainActor () -> Void] = []

    var count: Int {
        handoffs.count
    }

    func schedule(_ handoff: @escaping @MainActor () -> Void) {
        handoffs.append(handoff)
    }

    func runNext() {
        handoffs.removeFirst()()
    }
}

@MainActor
final class OverviewBehaviorTests: XCTestCase {
    private let screenFrame = CGRect(x: 0, y: 0, width: 1000, height: 800)

    func testRevealPreservesAlreadyVisibleOffset() {
        let layout = makeGeometryLayout()

        let offset = OverviewLayoutCalculator.scrollOffsetRevealing(
            targetFrame: CGRect(x: 100, y: 200, width: 300, height: 200),
            currentOffset: -50,
            layout: layout,
            screenFrame: screenFrame
        )

        XCTAssertEqual(offset, -50)
    }

    func testRevealChoosesNearestEdgeAboveAndBelow() {
        let layout = makeGeometryLayout()

        let below = OverviewLayoutCalculator.scrollOffsetRevealing(
            targetFrame: CGRect(x: 100, y: -200, width: 300, height: 100),
            currentOffset: 0,
            layout: layout,
            screenFrame: screenFrame
        )
        let above = OverviewLayoutCalculator.scrollOffsetRevealing(
            targetFrame: CGRect(x: 100, y: 150, width: 300, height: 100),
            currentOffset: -600,
            layout: layout,
            screenFrame: screenFrame
        )

        XCTAssertEqual(below, -216)
        XCTAssertEqual(above, -434)
    }

    func testRevealBoundsPaddingForNearlyViewportSizedCard() {
        let layout = makeGeometryLayout()
        let target = CGRect(x: 0, y: -100, width: 900, height: 694)

        let offset = OverviewLayoutCalculator.scrollOffsetRevealing(
            targetFrame: target,
            currentOffset: 0,
            layout: layout,
            screenFrame: screenFrame
        )

        XCTAssertEqual(offset, -103)
        assertVisible(target, in: layout, offset: offset)
    }

    func testRevealAlignsOversizedCardToContentTop() {
        let layout = makeGeometryLayout()
        let target = CGRect(x: 0, y: -500, width: 900, height: 800)

        let offset = OverviewLayoutCalculator.scrollOffsetRevealing(
            targetFrame: target,
            currentOffset: 0,
            layout: layout,
            screenFrame: screenFrame
        )

        XCTAssertEqual(offset, -400)
        let viewport = OverviewLayoutCalculator.visibleContentFrame(
            layout: layout,
            screenFrame: screenFrame,
            scrollOffset: offset
        )
        XCTAssertEqual(target.maxY, viewport.maxY)
    }

    func testRevealClampsAtBothScrollBounds() {
        let layout = makeGeometryLayout()

        let bottom = OverviewLayoutCalculator.scrollOffsetRevealing(
            targetFrame: CGRect(x: 0, y: -2200, width: 200, height: 100),
            currentOffset: 0,
            layout: layout,
            screenFrame: screenFrame
        )
        let top = OverviewLayoutCalculator.scrollOffsetRevealing(
            targetFrame: CGRect(x: 0, y: 1200, width: 200, height: 100),
            currentOffset: -600,
            layout: layout,
            screenFrame: screenFrame
        )

        XCTAssertEqual(bottom, -1300)
        XCTAssertEqual(top, 0)
    }

    func testRevealPreservesFractionalCoordinates() {
        let layout = makeGeometryLayout()

        let offset = OverviewLayoutCalculator.scrollOffsetRevealing(
            targetFrame: CGRect(x: 0, y: -10.25, width: 200, height: 99.5),
            currentOffset: 0,
            layout: layout,
            screenFrame: screenFrame
        )

        XCTAssertEqual(offset, -26.25, accuracy: 0.0001)
    }

    func testRevealAtEverySupportedZoomStepRemainsBoundedAndVisible() {
        for percentage in stride(from: 50, through: 150, by: 5) {
            let scale = CGFloat(percentage) / 100
            let layout = makeGeometryLayout(scale: scale)
            let target = CGRect(x: 0, y: -250, width: 300, height: 80)

            let offset = OverviewLayoutCalculator.scrollOffsetRevealing(
                targetFrame: target,
                currentOffset: 0,
                layout: layout,
                screenFrame: screenFrame
            )

            XCTAssertTrue(
                OverviewLayoutCalculator.scrollOffsetBounds(layout: layout, screenFrame: screenFrame)
                    .contains(offset),
                "zoom \(percentage)%"
            )
            assertVisible(target, in: layout, offset: offset, message: "zoom \(percentage)%")
        }
    }

    func testNavigationRevealsThirdWorkspaceAndKeepsSingleWindowRowSelection() throws {
        let fixture = makeProjectionFixture()
        var layout = projectedLayout(fixture: fixture, scale: 1, query: "")
        let first = try XCTUnwrap(layout.allWindows.first?.handle)

        let second = try XCTUnwrap(
            OverviewNavigation.findNextWindow(in: layout, from: first, direction: .down)
        )
        let third = try XCTUnwrap(
            OverviewNavigation.findNextWindow(in: layout, from: second, direction: .down)
        )
        let thirdWindow = try XCTUnwrap(layout.window(for: third))
        layout.scrollOffset = OverviewLayoutCalculator.scrollOffsetRevealing(
            targetFrame: thirdWindow.overviewFrame,
            currentOffset: layout.scrollOffset,
            layout: layout,
            screenFrame: screenFrame
        )

        assertVisible(thirdWindow.overviewFrame, in: layout, offset: layout.scrollOffset)
        XCTAssertTrue(layout.scrollOffset < 0)
        XCTAssertEqual(
            OverviewNavigation.findNextWindow(in: layout, from: third, direction: .right),
            third
        )
        XCTAssertEqual(
            OverviewNavigation.findNextWindow(in: layout, from: first, direction: .left),
            first
        )
        XCTAssertEqual(
            OverviewNavigation.cycledSelection(in: layout, from: .window(third), forward: true, searching: false),
            .window(third)
        )
        XCTAssertEqual(
            OverviewNavigation.cycledSelection(in: layout, from: .window(first), forward: false, searching: false),
            .window(first)
        )
    }

    func testHorizontalNavigationStopsAtCurrentWorkspaceRowEnds() throws {
        let fixture = makeProjectionFixture(windowCountsPerWorkspace: [3, 3, 3])
        let layout = projectedLayout(fixture: fixture, scale: 1, query: "")

        for (rowIndex, row) in fixture.rowHandles.enumerated() {
            let leftEdge = try XCTUnwrap(row.first)
            let rightEdge = try XCTUnwrap(row.last)

            XCTAssertEqual(
                OverviewNavigation.findNextWindow(in: layout, from: leftEdge, direction: .left),
                leftEdge,
                "left edge of workspace row \(rowIndex) must stop"
            )
            XCTAssertEqual(
                OverviewNavigation.findNextWindow(in: layout, from: rightEdge, direction: .right),
                rightEdge,
                "right edge of workspace row \(rowIndex) must stop"
            )
        }

        let firstRow = fixture.rowHandles[0]
        XCTAssertEqual(
            OverviewNavigation.findNextWindow(in: layout, from: firstRow[0], direction: .right),
            firstRow[1]
        )
        XCTAssertEqual(
            OverviewNavigation.findNextWindow(in: layout, from: firstRow[2], direction: .left),
            firstRow[1]
        )
    }

    func testHorizontalNavigationKeepsLoneWindowRowSelectionInPlace() throws {
        let fixture = makeProjectionFixture(windowCountsPerWorkspace: [3, 1, 2])
        let layout = projectedLayout(fixture: fixture, scale: 1, query: "")
        let loneWindow = try XCTUnwrap(fixture.rowHandles[1].first)

        XCTAssertEqual(
            OverviewNavigation.findNextWindow(in: layout, from: loneWindow, direction: .right),
            loneWindow
        )
        XCTAssertEqual(
            OverviewNavigation.findNextWindow(in: layout, from: loneWindow, direction: .left),
            loneWindow
        )

        let multiWindowRow = fixture.rowHandles[0]
        XCTAssertEqual(
            OverviewNavigation.findNextWindow(in: layout, from: multiWindowRow.first, direction: .left),
            multiWindowRow.first
        )
        XCTAssertEqual(
            OverviewNavigation.findNextWindow(in: layout, from: multiWindowRow.last, direction: .right),
            multiWindowRow.last
        )
    }

    func testHorizontalNavigationDoesNotCrossVerticallyOverlappingWorkspaces() throws {
        let tallDescriptor = WorkspaceDescriptor(name: "Tall")
        let shortDescriptor = WorkspaceDescriptor(name: "Short")
        let workspaces: [OverviewWorkspaceLayoutItem] = [
            OverviewWorkspaceLayoutItem(id: tallDescriptor.id, name: tallDescriptor.name, isActive: true),
            OverviewWorkspaceLayoutItem(id: shortDescriptor.id, name: shortDescriptor.name, isActive: false)
        ]
        var windows: [WindowHandle: OverviewWindowLayoutData] = [:]
        let tallToken = WindowToken(pid: 1, windowId: 1)
        let tallHandle = WindowHandle(id: tallToken)
        windows[tallHandle] = OverviewWindowLayoutData(
            token: tallToken,
            workspaceId: tallDescriptor.id,
            title: "Tall 1",
            appName: "App 1",
            appIcon: nil,
            frame: CGRect(x: 0, y: 0, width: 1000, height: 700)
        )
        var shortHandles: [WindowHandle] = []
        for slot in 0 ..< 2 {
            let token = WindowToken(pid: pid_t(2 + slot), windowId: 2 + slot)
            let handle = WindowHandle(id: token)
            windows[handle] = OverviewWindowLayoutData(
                token: token,
                workspaceId: shortDescriptor.id,
                title: "Short \(slot + 1)",
                appName: "App \(2 + slot)",
                appIcon: nil,
                frame: CGRect(x: CGFloat(slot) * 500, y: 0, width: 500, height: 233)
            )
            shortHandles.append(handle)
        }
        let layout = projectedLayout(
            fixture: ProjectionFixture(workspaces: workspaces, windows: windows),
            scale: 1,
            query: ""
        )

        XCTAssertEqual(
            OverviewNavigation.findNextWindow(in: layout, from: tallHandle, direction: .left),
            tallHandle
        )
        XCTAssertEqual(
            OverviewNavigation.findNextWindow(in: layout, from: tallHandle, direction: .right),
            tallHandle
        )
        XCTAssertEqual(
            OverviewNavigation.findNextWindow(in: layout, from: shortHandles[0], direction: .right),
            shortHandles[1]
        )
    }

    func testHorizontalNavigationKeepsLoneRowMatchSelectionWhileSearching() throws {
        let fixture = makeProjectionFixture(windowCountsPerWorkspace: [3, 3, 3])
        let layout = projectedLayout(fixture: fixture, scale: 1, query: "2")

        for (rowIndex, row) in fixture.rowHandles.enumerated() {
            let loneMatch = row[1]

            XCTAssertEqual(
                OverviewNavigation.findNextWindow(in: layout, from: loneMatch, direction: .right),
                loneMatch,
                "workspace row \(rowIndex)"
            )
            XCTAssertEqual(
                OverviewNavigation.findNextWindow(in: layout, from: loneMatch, direction: .left),
                loneMatch,
                "workspace row \(rowIndex)"
            )
        }

        let matchingHandles = fixture.rowHandles.map { $0[1] }
        XCTAssertEqual(
            OverviewNavigation.cycledSelection(
                in: layout,
                from: .window(matchingHandles[0]),
                forward: true, searching: true
            ),
            .window(matchingHandles[1])
        )
        XCTAssertEqual(
            OverviewNavigation.cycledSelection(
                in: layout,
                from: .window(matchingHandles[0]),
                forward: false, searching: true
            ),
            .window(matchingHandles[0])
        )
    }

    func testZoomPreservesSelectedMidpointsIndependentlyUntilClamped() throws {
        let fixture = makeProjectionFixture()
        var firstMonitor = projectedLayout(fixture: fixture, scale: 1, query: "")
        var secondMonitor = firstMonitor
        let selected = try XCTUnwrap(firstMonitor.allWindows.last?.handle)
        firstMonitor.scrollOffset = -500
        secondMonitor.scrollOffset = -700
        let firstMidpoint = try XCTUnwrap(firstMonitor.window(for: selected)).overviewFrame.midY
            - firstMonitor.scrollOffset
        let secondMidpoint = try XCTUnwrap(secondMonitor.window(for: selected)).overviewFrame.midY
            - secondMonitor.scrollOffset

        var zoomedFirst = projectedLayout(fixture: fixture, scale: 1.5, query: "")
        var zoomedSecond = zoomedFirst
        let zoomedWindow = try XCTUnwrap(zoomedFirst.window(for: selected))
        let firstDesiredOffset = zoomedWindow.overviewFrame.midY - firstMidpoint
        let secondDesiredOffset = zoomedWindow.overviewFrame.midY - secondMidpoint
        zoomedFirst.scrollOffset = OverviewLayoutCalculator.clampedScrollOffset(
            firstDesiredOffset,
            layout: zoomedFirst,
            screenFrame: screenFrame
        )
        zoomedSecond.scrollOffset = OverviewLayoutCalculator.clampedScrollOffset(
            secondDesiredOffset,
            layout: zoomedSecond,
            screenFrame: screenFrame
        )

        XCTAssertNotEqual(zoomedFirst.scrollOffset, zoomedSecond.scrollOffset)
        XCTAssertEqual(
            zoomedWindow.overviewFrame.midY - zoomedFirst.scrollOffset,
            firstMidpoint,
            accuracy: 0.0001
        )
        XCTAssertFalse(
            OverviewLayoutCalculator.scrollOffsetBounds(layout: zoomedSecond, screenFrame: screenFrame)
                .contains(secondDesiredOffset)
        )
        XCTAssertEqual(
            zoomedSecond.scrollOffset,
            OverviewLayoutCalculator.clampedScrollOffset(
                secondDesiredOffset,
                layout: zoomedSecond,
                screenFrame: screenFrame
            )
        )
    }

    func testSelectionSearchZoomRemovalSequenceMaintainsViewportInvariants() throws {
        var fixture = makeProjectionFixture()
        var layout = projectedLayout(fixture: fixture, scale: 1, query: "")
        let first = try XCTUnwrap(layout.allWindows.first?.handle)
        var selectedHandle = first
        assertViewportInvariant(layout, selectedHandle: selectedHandle)

        let second = try XCTUnwrap(
            OverviewNavigation.findNextWindow(in: layout, from: first, direction: .down)
        )
        let third = try XCTUnwrap(
            OverviewNavigation.findNextWindow(in: layout, from: second, direction: .down)
        )
        selectedHandle = third
        revealSelection(selectedHandle, in: &layout)
        assertViewportInvariant(layout, selectedHandle: selectedHandle)

        let previousOffset = layout.scrollOffset
        layout = projectedLayout(fixture: fixture, scale: 1, query: "third")
        layout.scrollOffset = OverviewLayoutCalculator.clampedScrollOffset(
            previousOffset,
            layout: layout,
            screenFrame: screenFrame
        )
        revealSelection(selectedHandle, in: &layout)
        assertViewportInvariant(layout, selectedHandle: selectedHandle)

        let midpoint = try XCTUnwrap(layout.window(for: third)).overviewFrame.midY - layout.scrollOffset
        layout = projectedLayout(fixture: fixture, scale: 1.5, query: "third")
        let zoomedWindow = try XCTUnwrap(layout.window(for: third))
        layout.scrollOffset = OverviewLayoutCalculator.clampedScrollOffset(
            zoomedWindow.overviewFrame.midY - midpoint,
            layout: layout,
            screenFrame: screenFrame
        )
        revealSelection(selectedHandle, in: &layout)
        assertViewportInvariant(layout, selectedHandle: selectedHandle)

        fixture.windows.removeValue(forKey: third)
        layout = projectedLayout(fixture: fixture, scale: 1.5, query: "")
        selectedHandle = try XCTUnwrap(layout.allWindows.first?.handle)
        revealSelection(selectedHandle, in: &layout)
        assertViewportInvariant(layout, selectedHandle: selectedHandle)
    }

    func testActivationAndDismissalDoNotRepeatWhileNavigationAndCyclingDo() {
        let repeatedReturn = OverviewInputHandler.keyHandlingResult(
            keyCode: UInt16(kVK_Return),
            modifierFlags: [],
            charactersIgnoringModifiers: "\r",
            searchQuery: "",
            isRepeat: true
        )
        let repeatedEscape = OverviewInputHandler.keyHandlingResult(
            keyCode: UInt16(kVK_Escape),
            modifierFlags: [],
            charactersIgnoringModifiers: nil,
            searchQuery: "query",
            isRepeat: true
        )
        let repeatedArrow = OverviewInputHandler.keyHandlingResult(
            keyCode: UInt16(kVK_DownArrow),
            modifierFlags: [],
            charactersIgnoringModifiers: nil,
            searchQuery: "",
            isRepeat: true
        )
        let repeatedTab = OverviewInputHandler.keyHandlingResult(
            keyCode: UInt16(kVK_Tab),
            modifierFlags: .shift,
            charactersIgnoringModifiers: "\t",
            searchQuery: "",
            isRepeat: true
        )
        let forwardTab = OverviewInputHandler.keyHandlingResult(
            keyCode: UInt16(kVK_Tab),
            modifierFlags: [],
            charactersIgnoringModifiers: "\t",
            searchQuery: ""
        )

        XCTAssertEqual(repeatedReturn.action, .consume)
        XCTAssertTrue(repeatedReturn.shouldConsume)
        XCTAssertEqual(repeatedEscape.action, .consume)
        XCTAssertTrue(repeatedEscape.shouldConsume)
        XCTAssertEqual(repeatedArrow.action, .navigate(.down))
        XCTAssertEqual(repeatedTab.action, .cycleSelection(forward: false))
        XCTAssertEqual(forwardTab.action, .cycleSelection(forward: true))
    }

    func testEscapeDismissesSelectionEvenWithSearch() {
        let firstEscape = OverviewInputHandler.keyHandlingResult(
            keyCode: UInt16(kVK_Escape),
            modifierFlags: [],
            charactersIgnoringModifiers: nil,
            searchQuery: "query",
            isRepeat: false
        )
        let repeatedEscape = OverviewInputHandler.keyHandlingResult(
            keyCode: UInt16(kVK_Escape),
            modifierFlags: [],
            charactersIgnoringModifiers: nil,
            searchQuery: "",
            isRepeat: true
        )

        XCTAssertEqual(firstEscape.action, .dismissSelection)
        XCTAssertEqual(repeatedEscape.action, .consume)
    }

    func testOrdinaryTypingIncludesLowercaseAndUppercaseWAndRepeats() {
        for word in ["qwerty", "WezTerm", "W", "www"] {
            for repeats in [false, true] {
                var query = ""
                for character in word {
                    let code = character.lowercased() == "w" ? kVK_ANSI_W : kVK_ANSI_Q
                    let result = OverviewInputHandler.keyHandlingResult(
                        keyCode: UInt16(code), modifierFlags: character.isUppercase ? .shift : [],
                        charactersIgnoringModifiers: String(character), searchQuery: query, isRepeat: repeats
                    )
                    XCTAssertEqual(result.action, .appendToSearch(String(character)))
                    if case let .appendToSearch(text) = result.action { query += text }
                }
                XCTAssertEqual(query, word)
            }
        }
    }

    func testInteractiveZoomIsRememberedOnlyOnCloseAndSurvivesReopenAndServiceStop() throws {
        let fixture = try makeRuntimeOverviewFixture(windowCount: 1)
        var environment = fixture.environment
        environment.frontmostApplicationPID = { nil }
        environment.activateOmniWM = {}
        environment.addLocalEventMonitor = { _, _ in nil }
        let overview = OverviewController(
            wmController: fixture.controller, motionPolicy: fixture.controller.motionPolicy, environment: environment
        )
        let settings = fixture.controller.settings
        let monitorId = try XCTUnwrap(fixture.controller.workspaceManager.monitors.first?.id)
        let zoom = OverviewScrollInput.Event(
            deltaX: 0, deltaY: 1, modifiers: [.option, .shift], isPrecise: true, location: .zero
        )
        var saves = 0
        settings.overview.onChange = { saves += 1 }
        overview.prepareOpenState()
        overview.onAnimationComplete(state: .open)
        overview.input.handleScroll(zoom, on: monitorId)
        XCTAssertEqual(settings.overview.zoom, 1)
        XCTAssertEqual(saves, 0)
        overview.dismiss(animated: false)
        XCTAssertEqual(settings.overview.zoom, 1.05, accuracy: 0.0001)
        XCTAssertEqual(saves, 1)
        overview.prepareOpenState()
        overview.onAnimationComplete(state: .open)
        overview.input.handleScroll(zoom, on: monitorId)
        overview.invalidateDeferredActionsForServiceStop()
        XCTAssertEqual(settings.overview.zoom, 1.1, accuracy: 0.0001)
        XCTAssertEqual(saves, 2)
        overview.invalidateDeferredActionsForServiceStop()
        XCTAssertEqual(saves, 2)
        settings.flushNow()
        let persisted = try SettingsTOMLCodec.decode(Data(contentsOf: settings.settingsFileURL))
        XCTAssertEqual(persisted.overview.zoom, 1.1, accuracy: 0.0001)
        settings.applyExport(persisted)
        saves = 0
        overview.prepareOpenState()
        overview.onAnimationComplete(state: .open)
        overview.dismiss(animated: false)
        XCTAssertEqual(settings.overview.zoom, 1.1, accuracy: 0.0001)
        XCTAssertEqual(saves, 0)
    }

    func testReversingCloseDoesNotSaveOrResetInteractiveZoom() throws {
        let fixture = try makeRuntimeOverviewFixture(windowCount: 1)
        fixture.controller.motionPolicy.animationsEnabled = true
        let clock = OverviewAnimationTestClock()
        var environment = fixture.environment
        environment.frontmostApplicationPID = { nil }
        environment.activateOmniWM = {}
        environment.addLocalEventMonitor = { _, _ in nil }
        let overview = OverviewController(
            wmController: fixture.controller, motionPolicy: fixture.controller.motionPolicy,
            environment: environment, animationInstaller: { _, _, _ in true },
            animationMediaTimeProvider: { clock.time }
        )
        overview.open()
        clock.time = 10
        overview.onAnimationComplete(state: .open)
        let monitorId = try XCTUnwrap(fixture.controller.workspaceManager.monitors.first?.id)
        let zoom = OverviewScrollInput.Event(
            deltaX: 0, deltaY: 1, modifiers: [.option, .shift], isPrecise: false, location: .zero
        )
        overview.input.handleScroll(zoom, on: monitorId)
        overview.dismiss(animated: true)
        XCTAssertEqual(fixture.controller.settings.overview.zoom, 1)
        guard case .closing = overview.state else { return XCTFail("Expected an in-flight close") }
        clock.time = 10.03
        overview.toggle()
        overview.onAnimationComplete(state: .open)
        overview.input.handleScroll(zoom, on: monitorId)
        overview.dismiss(animated: false)
        XCTAssertEqual(fixture.controller.settings.overview.zoom, 1.1, accuracy: 0.0001)
    }

    func testCommandWClosesSelectionWithoutRepeating() {
        let commandW = OverviewInputHandler.keyHandlingResult(
            keyCode: UInt16(kVK_ANSI_W),
            modifierFlags: .command,
            charactersIgnoringModifiers: "w",
            searchQuery: "",
            isRepeat: false
        )
        let repeatedCommandW = OverviewInputHandler.keyHandlingResult(
            keyCode: UInt16(kVK_ANSI_W),
            modifierFlags: .command,
            charactersIgnoringModifiers: "w",
            searchQuery: "",
            isRepeat: true
        )

        XCTAssertEqual(commandW.action, .closeSelection)
        XCTAssertEqual(repeatedCommandW.action, .consume)
    }

    func testRegisteredEscapeUsesPhysicalDismissalBeforeAssignedCommand() throws {
        let fixture = try makeRuntimeOverviewFixture(windowCount: 1)
        let handoffScheduler = OverviewPostCloseHandoffScheduler()
        var environment = fixture.environment
        environment.schedulePostCloseHandoff = handoffScheduler.schedule
        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy,
            environment: environment
        )
        overview.prepareOpenState()
        overview.onAnimationComplete(state: .open)
        let selectedHandle = try XCTUnwrap(overview.selectedWindowHandle)
        var activatedHandle: WindowHandle?
        overview.onActivateWindow = { handle, _ in activatedHandle = handle }

        let disposition = overview.input.handleHotkeyInvocation(
            HotkeyInvocation(
                command: .fullscreen(.managed),
                trigger: PhysicalHotkeyTrigger(
                    keyCode: UInt32(kVK_Escape),
                    modifiers: UInt32(optionKey),
                    isRepeat: false
                )
            )
        )

        XCTAssertEqual(disposition, .handled)
        XCTAssertNil(activatedHandle)
        XCTAssertEqual(handoffScheduler.count, 1)
        handoffScheduler.runNext()
        XCTAssertEqual(activatedHandle, selectedHandle)
        XCTAssertFalse(overview.state.isOpen)
    }

    func testOverviewToggleCloseFocusesCurrentSelection() throws {
        let fixture = try makeRuntimeOverviewFixture(windowCount: 1)
        let handoffScheduler = OverviewPostCloseHandoffScheduler()
        var environment = fixture.environment
        environment.schedulePostCloseHandoff = handoffScheduler.schedule
        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy,
            environment: environment
        )
        overview.prepareOpenState()
        overview.onAnimationComplete(state: .open)
        let selectedHandle = try XCTUnwrap(overview.selectedWindowHandle)
        var activatedHandle: WindowHandle?
        overview.onActivateWindow = { handle, _ in activatedHandle = handle }

        XCTAssertEqual(overview.input.handleHotkeyCommand(.presentation(.overview)), .handled)

        XCTAssertNil(activatedHandle)
        XCTAssertEqual(handoffScheduler.count, 1)
        handoffScheduler.runNext()
        XCTAssertEqual(activatedHandle, selectedHandle)
        XCTAssertFalse(overview.state.isOpen)
    }

    func testRegisteredCommandWConsumesRepeatAndClosesOnce() throws {
        let fixture = try makeRuntimeOverviewFixture(windowCount: 1)
        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy,
            environment: fixture.environment
        )
        overview.prepareOpenState()
        overview.onAnimationComplete(state: .open)
        var closeCount = 0
        overview.onCloseWindow = { _ in
            closeCount += 1
            return true
        }

        let repeated = HotkeyInvocation(
            command: .fullscreen(.managed),
            trigger: PhysicalHotkeyTrigger(
                keyCode: UInt32(kVK_ANSI_W),
                modifiers: UInt32(cmdKey),
                isRepeat: true
            )
        )
        let initial = HotkeyInvocation(
            command: .fullscreen(.managed),
            trigger: PhysicalHotkeyTrigger(
                keyCode: UInt32(kVK_ANSI_W),
                modifiers: UInt32(cmdKey),
                isRepeat: false
            )
        )

        XCTAssertEqual(overview.input.handleHotkeyInvocation(repeated), .handled)
        XCTAssertEqual(closeCount, 0)
        XCTAssertEqual(overview.input.handleHotkeyInvocation(initial), .handled)
        XCTAssertEqual(closeCount, 1)
        XCTAssertTrue(overview.state.isOpen)
    }

    func testRepeatedRegisteredOverviewToggleIsConsumedWhileClosed() throws {
        let fixture = try makeRuntimeOverviewFixture(windowCount: 1)
        let result = fixture.controller.commandHandler.handleHotkeyInvocation(
            HotkeyInvocation(
                command: .presentation(.overview),
                trigger: PhysicalHotkeyTrigger(
                    keyCode: UInt32(kVK_ANSI_O),
                    modifiers: UInt32(optionKey),
                    isRepeat: true
                )
            )
        )

        XCTAssertEqual(result, .executed)
        XCTAssertFalse(fixture.controller.isOverviewOpen())
    }

    func testRemovalSelectionChoosesNextThenPrevious() {
        let handles = (1 ... 3).map { index in
            WindowHandle(id: WindowToken(pid: pid_t(index), windowId: index))
        }

        XCTAssertEqual(
            OverviewNavigation.selectionAfterRemoving(
                handles[1],
                from: handles,
                availableHandles: [handles[0], handles[2]]
            ),
            handles[2]
        )
        XCTAssertEqual(
            OverviewNavigation.selectionAfterRemoving(
                handles[2],
                from: handles,
                availableHandles: [handles[0], handles[1]]
            ),
            handles[1]
        )
        XCTAssertNil(
            OverviewNavigation.selectionAfterRemoving(
                handles[0],
                from: handles,
                availableHandles: []
            )
        )
    }

    func testSelectionDismissalFocusesCurrentOverviewSelection() throws {
        let fixture = try makeRuntimeOverviewFixture(windowCount: 2)
        let handoffScheduler = OverviewPostCloseHandoffScheduler()
        var environment = fixture.environment
        environment.schedulePostCloseHandoff = handoffScheduler.schedule
        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy,
            environment: environment
        )
        overview.prepareOpenState()
        overview.onAnimationComplete(state: .open)
        let selectedHandle = try XCTUnwrap(overview.selectedWindowHandle)
        var activatedHandle: WindowHandle?
        var activatedWorkspaceId: WorkspaceDescriptor.ID?
        var wasOpenAtActivation: Bool?
        overview.onActivateWindow = { handle, workspaceId in
            activatedHandle = handle
            activatedWorkspaceId = workspaceId
            wasOpenAtActivation = overview.state.isOpen
        }

        overview.input.dismissToSelection(animated: false)

        XCTAssertNil(activatedHandle)
        XCTAssertEqual(handoffScheduler.count, 1)
        XCTAssertFalse(overview.state.isOpen)
        handoffScheduler.runNext()
        XCTAssertEqual(activatedHandle, selectedHandle)
        XCTAssertEqual(activatedWorkspaceId, fixture.workspaceId)
        XCTAssertEqual(wasOpenAtActivation, false)
    }

    func testRepeatedSelectionDismissalClosesOpeningAndOpenOverviewOnce() throws {
        for dismissDuringOpening in [true, false] {
            let fixture = try makeRuntimeOverviewFixture(windowCount: 1)
            fixture.controller.motionPolicy.animationsEnabled = true
            let handoffScheduler = OverviewPostCloseHandoffScheduler()
            let clock = OverviewAnimationTestClock()
            var environment = fixture.environment
            environment.schedulePostCloseHandoff = handoffScheduler.schedule
            var animationCompletions: [OverviewAnimationCompletion] = []
            let overview = OverviewController(
                wmController: fixture.controller,
                motionPolicy: fixture.controller.motionPolicy,
                environment: environment,
                animationInstaller: { _, _, completion in
                    animationCompletions.append(completion)
                    return true
                },
                animationMediaTimeProvider: { clock.time }
            )
            overview.open()
            if dismissDuringOpening {
                clock.time = 0.03
            } else {
                clock.time = 10
                try XCTUnwrap(animationCompletions.last).complete()
            }
            let selectedHandle = try XCTUnwrap(overview.selectedWindowHandle)
            var activatedHandles: [WindowHandle] = []
            overview.onActivateWindow = { [weak overview] handle, _ in
                XCTAssertEqual(overview?.isOpen, false)
                activatedHandles.append(handle)
            }

            overview.input.dismissToSelection(animated: true)
            let closeSubmissionCount = animationCompletions.count
            let closeCompletion = try XCTUnwrap(animationCompletions.last)
            overview.input.dismissToSelection(animated: true)

            guard case let .closing(targetWindow) = overview.state else {
                return XCTFail("Expected repeated dismissal to keep overview closing")
            }
            XCTAssertTrue(targetWindow === selectedHandle)
            XCTAssertEqual(animationCompletions.count, closeSubmissionCount)
            XCTAssertEqual(handoffScheduler.count, 0)
            XCTAssertTrue(activatedHandles.isEmpty)

            closeCompletion.complete()
            overview.input.dismissToSelection(animated: true)

            XCTAssertFalse(overview.isOpen)
            XCTAssertEqual(animationCompletions.count, closeSubmissionCount)
            XCTAssertEqual(handoffScheduler.count, 1)
            XCTAssertTrue(activatedHandles.isEmpty)
            handoffScheduler.runNext()
            XCTAssertEqual(activatedHandles, [selectedHandle])
        }
    }

    func testPostCloseFocusHandoffSurvivesWindowVisibilityChange() throws {
        let fixture = try makeRuntimeOverviewFixture(windowCount: 2)
        let handoffScheduler = OverviewPostCloseHandoffScheduler()
        var environment = fixture.environment
        environment.schedulePostCloseHandoff = handoffScheduler.schedule
        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy,
            environment: environment
        )
        overview.prepareOpenState()
        overview.onAnimationComplete(state: .open)
        let selectedHandle = try XCTUnwrap(overview.selectedWindowHandle)
        let otherHandle = try XCTUnwrap(fixture.handles.first { $0.id != selectedHandle.id })
        fixture.controller.workspaceManager.setHiddenState(
            HiddenState(proportionalPosition: .zero, referenceMonitorId: nil, reason: .layoutTransient(.left)),
            for: otherHandle.id
        )
        var activatedHandle: WindowHandle?
        overview.onActivateWindow = { handle, _ in activatedHandle = handle }

        overview.input.dismissToSelection(animated: false)
        fixture.controller.workspaceManager.setHiddenState(nil, for: otherHandle.id)
        handoffScheduler.runNext()

        XCTAssertEqual(activatedHandle, selectedHandle)
    }

    func testFocusHandoffSurvivesVisibilityChangeDuringNativeClose() throws {
        let fixture = try makeRuntimeOverviewFixture(windowCount: 2)
        fixture.controller.motionPolicy.animationsEnabled = true
        let handoffScheduler = OverviewPostCloseHandoffScheduler()
        var environment = fixture.environment
        environment.schedulePostCloseHandoff = handoffScheduler.schedule
        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy,
            environment: environment,
            animationInstaller: { _, _, _ in true },
            animationMediaTimeProvider: { 0 }
        )
        overview.open()
        overview.onAnimationComplete(state: .open)
        let selected = try XCTUnwrap(overview.selectedWindowHandle)
        let other = try XCTUnwrap(fixture.handles.first { $0.id != selected.id })
        var activatedHandle: WindowHandle?
        overview.onActivateWindow = { handle, _ in activatedHandle = handle }

        overview.input.dismissToSelection(animated: true)
        guard case .closing = overview.state else { return XCTFail("Expected a native close in flight") }
        fixture.controller.workspaceManager.setHiddenState(
            HiddenState(proportionalPosition: .zero, referenceMonitorId: nil, reason: .layoutTransient(.left)),
            for: other.id
        )
        XCTAssertEqual(handoffScheduler.count, 0)
        overview.completeCloseTransition(targetWindow: selected)
        XCTAssertEqual(handoffScheduler.count, 1)
        handoffScheduler.runNext()
        XCTAssertEqual(activatedHandle, selected)
    }

    func testSystemReduceMotionMakesOverviewTransitionsDiscrete() throws {
        let fixture = try makeRuntimeOverviewFixture(windowCount: 1)
        fixture.controller.motionPolicy.animationsEnabled = true
        fixture.controller.motionPolicy.systemReducesMotion = true
        var environment = fixture.environment
        environment.frontmostApplicationPID = { nil }
        environment.activateOmniWM = {}
        var installs = 0
        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy,
            environment: environment,
            animationInstaller: { _, _, _ in
                installs += 1
                return true
            },
            animationMediaTimeProvider: { 0 }
        )

        overview.open()

        guard case .open = overview.state else {
            return XCTFail("Expected Reduce Motion to open Overview discretely")
        }
        XCTAssertEqual(installs, 0)
        XCTAssertFalse(overview.beginInteractiveTransition())

        overview.dismiss(reason: .cancel, animated: true)

        guard case .closed = overview.state else {
            return XCTFail("Expected Reduce Motion to close Overview discretely")
        }
        XCTAssertEqual(installs, 0)
    }

    func testPostCloseFocusHandoffIsDiscardedAfterOverviewReopens() throws {
        let fixture = try makeRuntimeOverviewFixture(windowCount: 1)
        let handoffScheduler = OverviewPostCloseHandoffScheduler()
        var environment = fixture.environment
        environment.frontmostApplicationPID = { nil }
        environment.schedulePostCloseHandoff = handoffScheduler.schedule
        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy,
            environment: environment
        )
        overview.prepareOpenState()
        overview.onAnimationComplete(state: .open)
        var activatedHandle: WindowHandle?
        overview.onActivateWindow = { handle, _ in activatedHandle = handle }

        overview.input.dismissToSelection(animated: false)
        XCTAssertEqual(handoffScheduler.count, 1)

        overview.open()
        handoffScheduler.runNext()

        XCTAssertNil(activatedHandle)
        XCTAssertTrue(overview.state.isOpen)
        overview.completeCloseTransition(targetWindow: nil)
    }

    func testPostCloseFocusHandoffIsDiscardedAfterNewerFocusChange() throws {
        for externalFocusChange in [false, true] {
            let fixture = try makeRuntimeOverviewFixture(windowCount: 2)
            let handoffScheduler = OverviewPostCloseHandoffScheduler()
            var environment = fixture.environment
            environment.schedulePostCloseHandoff = handoffScheduler.schedule
            let overview = OverviewController(
                wmController: fixture.controller,
                motionPolicy: fixture.controller.motionPolicy,
                environment: environment
            )
            overview.prepareOpenState()
            overview.onAnimationComplete(state: .open)
            var activatedHandle: WindowHandle?
            overview.onActivateWindow = { handle, _ in activatedHandle = handle }

            overview.input.dismissToSelection(animated: false)
            if externalFocusChange {
                fixture.controller.workspaceManager.recordExternalFocus(pid: 91_299, windowId: 91_399)
            } else {
                _ = fixture.controller.intentLedger.beginManagedRequest(
                    token: fixture.handles[1].id,
                    workspaceId: fixture.workspaceId
                )
            }
            handoffScheduler.runNext()

            XCTAssertNil(activatedHandle)
        }
    }

    func testPostCloseFocusHandoffIsDiscardedAfterNewerAppActivationIntent() throws {
        let fixture = try makeRuntimeOverviewFixture(windowCount: 1)
        let handoffScheduler = OverviewPostCloseHandoffScheduler()
        var environment = fixture.environment
        environment.schedulePostCloseHandoff = handoffScheduler.schedule
        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy,
            environment: environment
        )
        overview.prepareOpenState()
        overview.onAnimationComplete(state: .open)
        var activatedHandle: WindowHandle?
        overview.onActivateWindow = { handle, _ in activatedHandle = handle }

        overview.input.dismissToSelection(animated: false)
        _ = fixture.controller.intentLedger.registerActivateApp(pid: 91_299)
        handoffScheduler.runNext()

        XCTAssertNil(activatedHandle)
    }

    func testPostCloseFocusHandoffIsDiscardedAfterIntentLedgerReset() throws {
        let fixture = try makeRuntimeOverviewFixture(windowCount: 1)
        let handoffScheduler = OverviewPostCloseHandoffScheduler()
        var environment = fixture.environment
        environment.schedulePostCloseHandoff = handoffScheduler.schedule
        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy,
            environment: environment
        )
        overview.prepareOpenState()
        overview.onAnimationComplete(state: .open)
        var activatedHandle: WindowHandle?
        overview.onActivateWindow = { handle, _ in activatedHandle = handle }

        overview.input.dismissToSelection(animated: false)
        fixture.controller.intentLedger.reset()
        handoffScheduler.runNext()

        XCTAssertNil(activatedHandle)
    }

    func testServiceStopInvalidationDiscardsQueuedPostCloseHandoff() throws {
        let fixture = try makeRuntimeOverviewFixture(windowCount: 1)
        let handoffScheduler = OverviewPostCloseHandoffScheduler()
        var environment = fixture.environment
        environment.schedulePostCloseHandoff = handoffScheduler.schedule
        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy,
            environment: environment
        )
        overview.prepareOpenState()
        overview.onAnimationComplete(state: .open)
        var activatedHandle: WindowHandle?
        overview.onActivateWindow = { handle, _ in activatedHandle = handle }

        overview.input.dismissToSelection(animated: false)
        overview.invalidateDeferredActionsForServiceStop()
        handoffScheduler.runNext()

        XCTAssertNil(activatedHandle)
    }

    func testServiceStopInvalidationClosesInFlightOverviewWithoutHandoff() throws {
        let fixture = try makeRuntimeOverviewFixture(windowCount: 1)
        fixture.controller.motionPolicy.animationsEnabled = true
        let handoffScheduler = OverviewPostCloseHandoffScheduler()
        var environment = fixture.environment
        environment.schedulePostCloseHandoff = handoffScheduler.schedule
        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy,
            environment: environment,
            animationInstaller: { _, _, _ in true },
            animationMediaTimeProvider: { 0 }
        )
        overview.open()
        overview.onAnimationComplete(state: .open)
        overview.input.dismissToSelection(animated: true)

        overview.invalidateDeferredActionsForServiceStop()

        guard case .closed = overview.state else {
            return XCTFail("Expected service stop to close the in-flight overview")
        }
        XCTAssertEqual(handoffScheduler.count, 0)
    }

    func testPostCloseFocusHandoffIsDiscardedAfterReusedAppActivationIntent() throws {
        let fixture = try makeRuntimeOverviewFixture(windowCount: 1)
        let handoffScheduler = OverviewPostCloseHandoffScheduler()
        var environment = fixture.environment
        environment.schedulePostCloseHandoff = handoffScheduler.schedule
        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy,
            environment: environment
        )
        overview.prepareOpenState()
        overview.onAnimationComplete(state: .open)
        var activatedHandle: WindowHandle?
        overview.onActivateWindow = { handle, _ in activatedHandle = handle }
        _ = fixture.controller.intentLedger.registerActivateApp(pid: 91_299)

        overview.input.dismissToSelection(animated: false)
        _ = fixture.controller.intentLedger.registerActivateApp(pid: 91_299)
        handoffScheduler.runNext()

        XCTAssertNil(activatedHandle)
    }

    func testPostCloseFocusHandoffIsDiscardedAfterNewerFocusIntentDuringClosing() throws {
        let fixture = try makeRuntimeOverviewFixture(windowCount: 2)
        fixture.controller.motionPolicy.animationsEnabled = true
        let handoffScheduler = OverviewPostCloseHandoffScheduler()
        var environment = fixture.environment
        environment.frontmostApplicationPID = { nil }
        environment.schedulePostCloseHandoff = handoffScheduler.schedule
        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy,
            environment: environment,
            animationInstaller: { _, _, _ in true },
            animationMediaTimeProvider: { 0 }
        )
        overview.open()
        overview.onAnimationComplete(state: .open)
        let selectedHandle = try XCTUnwrap(overview.selectedWindowHandle)
        let competingHandle = try XCTUnwrap(fixture.handles.first { $0.id != selectedHandle.id })
        var activatedHandle: WindowHandle?
        overview.onActivateWindow = { handle, _ in activatedHandle = handle }

        overview.input.dismissToSelection(animated: true)
        guard case .closing = overview.state else {
            return XCTFail("Expected selection dismissal to remain in closing state")
        }
        _ = fixture.controller.intentLedger.beginManagedRequest(
            token: competingHandle.id,
            workspaceId: fixture.workspaceId
        )
        overview.completeCloseTransition(targetWindow: selectedHandle)

        XCTAssertEqual(handoffScheduler.count, 1)
        handoffScheduler.runNext()
        XCTAssertNil(activatedHandle)
    }

    func testCancelApplicationHandoffIsDiscardedAfterFocusEpochChangesDuringClosing() throws {
        let fixture = try makeRuntimeOverviewFixture(windowCount: 1)
        fixture.controller.motionPolicy.animationsEnabled = true
        let handoffScheduler = OverviewPostCloseHandoffScheduler()
        var activatedPIDs: [pid_t] = []
        var environment = fixture.environment
        environment.frontmostApplicationPID = { 91_300 }
        environment.currentProcessID = { 91_301 }
        environment.activateApplication = { activatedPIDs.append($0) }
        environment.schedulePostCloseHandoff = handoffScheduler.schedule
        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy,
            environment: environment,
            animationInstaller: { _, _, _ in true },
            animationMediaTimeProvider: { 0 }
        )
        overview.open()
        overview.onAnimationComplete(state: .open)

        overview.dismiss(reason: .cancel, animated: true)
        guard case .closing = overview.state else {
            return XCTFail("Expected cancel dismissal to remain in closing state")
        }
        let focusEpochSeq = fixture.controller.workspaceManager.worldSeq
        XCTAssertTrue(
            fixture.controller.workspaceManager.beginManagedFocusRequest(
                fixture.handles[0].id,
                in: fixture.workspaceId,
                requestId: 91_302
            )
        )
        XCTAssertFalse(
            fixture.controller.workspaceManager.isSeqEpochCurrent(focusEpochSeq, domains: .focus)
        )
        overview.completeCloseTransition(targetWindow: nil)

        XCTAssertEqual(handoffScheduler.count, 1)
        handoffScheduler.runNext()
        XCTAssertTrue(activatedPIDs.isEmpty)
    }

    func testSelectionDismissalWithoutSelectionRestoresPreviousApplicationAfterSurfaceCompletion() throws {
        let fixture = try makeRuntimeOverviewFixture(windowCount: 1)
        let handoffScheduler = OverviewPostCloseHandoffScheduler()
        var activatedPIDs: [pid_t] = []
        var environment = fixture.environment
        environment.frontmostApplicationPID = { 91_300 }
        environment.currentProcessID = { 91_301 }
        environment.activateApplication = { activatedPIDs.append($0) }
        environment.schedulePostCloseHandoff = handoffScheduler.schedule
        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy,
            environment: environment
        )
        overview.beginOwnedSession()
        overview.onAnimationComplete(state: .open)

        XCTAssertNil(overview.selectedWindowHandle)
        overview.input.dismissToSelection(animated: false)

        XCTAssertTrue(activatedPIDs.isEmpty)
        XCTAssertFalse(overview.state.isOpen)
        XCTAssertEqual(handoffScheduler.count, 1)
        handoffScheduler.runNext()
        XCTAssertEqual(activatedPIDs, [91_300])
    }

    func testClosingStateFreezesKeyboardAndMouseSelection() throws {
        let fixture = try makeRuntimeOverviewFixture(windowCount: 2)
        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy,
            environment: fixture.environment
        )
        overview.prepareOpenState()
        overview.onAnimationComplete(state: .open)
        let originalSelection = try XCTUnwrap(overview.selectedWindowHandle)
        overview.input.cycleSelection(forward: true)

        let closingSelection = try XCTUnwrap(overview.selectedWindowHandle)
        XCTAssertNotEqual(closingSelection, originalSelection)
        overview.onAnimationComplete(state: .closing(targetWindow: closingSelection))

        overview.input.cycleSelection(forward: false)
        overview.input.selectAndActivateWindow(originalSelection)

        XCTAssertEqual(overview.selectedWindowHandle, closingSelection)
    }

    func testDismissalCancelsDragBeforeAnimatedCloseCompletes() throws {
        let fixture = try makeRuntimeOverviewFixture(windowCount: 1)
        fixture.controller.motionPolicy.animationsEnabled = true
        let handoffScheduler = OverviewPostCloseHandoffScheduler()
        var environment = fixture.environment
        environment.schedulePostCloseHandoff = handoffScheduler.schedule
        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy,
            environment: environment,
            animationInstaller: { _, _, _ in true },
            animationMediaTimeProvider: { 0 }
        )
        overview.open()
        overview.onAnimationComplete(state: .open)
        let selectedHandle = try XCTUnwrap(overview.selectedWindowHandle)
        let monitorId = try XCTUnwrap(fixture.controller.workspaceManager.monitors.first?.id)
        var activatedHandle: WindowHandle?
        overview.onActivateWindow = { handle, _ in activatedHandle = handle }

        overview.drag.beginDrag(on: monitorId, handle: selectedHandle, startPoint: .zero)
        XCTAssertTrue(overview.hasActiveDragSession)

        overview.input.dismissToSelection(animated: true)

        XCTAssertFalse(overview.hasActiveDragSession)
        guard case .closing = overview.state else {
            return XCTFail("Expected animated dismissal to remain in closing state")
        }
        overview.drag.endDrag(on: monitorId, at: CGPoint(x: 500, y: 500))
        XCTAssertEqual(
            fixture.controller.workspaceManager.workspace(for: selectedHandle.id),
            fixture.workspaceId
        )

        overview.completeCloseTransition(targetWindow: selectedHandle)
        XCTAssertNil(activatedHandle)
        handoffScheduler.runNext()
        XCTAssertEqual(activatedHandle, selectedHandle)
    }

    func testAnimatorRoutesIndependentDisplaySessionsThroughOneCompletionBarrier() throws {
        let fixture = try makeRuntimeOverviewFixture(windowCount: 1)
        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy,
            environment: fixture.environment
        )
        let animator = OverviewAnimator(
            controller: overview,
            animationInstaller: { _, _, _ in true },
            mediaTimeProvider: { 0 }
        )
        let firstDisplayId: CGDirectDisplayID = 91_001
        let secondDisplayId: CGDirectDisplayID = 91_002

        animator.startOpenAnimation(displayIds: [firstDisplayId, secondDisplayId])
        let generation = animator.generation

        XCTAssertEqual(animator.activeDisplayIds, [firstDisplayId, secondDisplayId])
        XCTAssertEqual(animator.completionCount, 0)

        completeAnimator(animator, displayId: firstDisplayId, generation: generation)
        XCTAssertEqual(animator.activeDisplayIds, [secondDisplayId])
        XCTAssertEqual(animator.completionCount, 0)

        completeAnimator(animator, displayId: secondDisplayId, generation: generation)

        XCTAssertTrue(animator.activeDisplayIds.isEmpty)
        XCTAssertEqual(animator.completedGeneration, generation)
        XCTAssertEqual(animator.completionCount, 1)
        guard case .open = overview.state else {
            return XCTFail("Expected the shared barrier to complete the open transition")
        }

        animator.animationCompleted(
            displayId: secondDisplayId,
            generation: generation
        )
        XCTAssertEqual(animator.completionCount, 1)
    }

    func testAnimatorIgnoresSupersededGenerationCallbacks() throws {
        let fixture = try makeRuntimeOverviewFixture(windowCount: 1)
        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy,
            environment: fixture.environment
        )
        let animator = OverviewAnimator(
            controller: overview,
            animationInstaller: { _, _, _ in true },
            mediaTimeProvider: { 0 }
        )
        let displayId: CGDirectDisplayID = 91_001

        animator.startOpenAnimation(displayIds: [displayId])
        let supersededGeneration = animator.generation
        animator.startOpenAnimation(displayIds: [displayId])
        let activeGeneration = animator.generation

        animator.animationCompleted(
            displayId: displayId,
            generation: supersededGeneration
        )
        XCTAssertEqual(animator.activeDisplayIds, [displayId])
        XCTAssertEqual(animator.completionCount, 0)

        animator.animationCompleted(
            displayId: displayId,
            generation: activeGeneration
        )
        animator.animationCompleted(
            displayId: displayId,
            generation: activeGeneration
        )
        XCTAssertEqual(animator.completionCount, 1)
    }

    func testAnimatorWaitsForEveryInstallBeforeDeliveringSynchronousCompletion() throws {
        let fixture = try makeRuntimeOverviewFixture(windowCount: 1)
        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy,
            environment: fixture.environment
        )
        var completionCountsDuringInstallation: [UInt64] = []
        let animator = OverviewAnimator(
            controller: overview,
            animationInstaller: { _, _, completion in
                completion.complete()
                completionCountsDuringInstallation.append(completion.animator?.completionCount ?? .max)
                return true
            },
            mediaTimeProvider: { 0 }
        )

        animator.startOpenAnimation(displayIds: [91_001, 91_002])

        XCTAssertEqual(completionCountsDuringInstallation, [0, 0])
        XCTAssertEqual(animator.completionCount, 1)
        XCTAssertTrue(animator.activeDisplayIds.isEmpty)
    }

    func testAnimatorDoesNotCompleteFromElapsedTimeWithoutNativeCompletion() throws {
        let fixture = try makeRuntimeOverviewFixture(windowCount: 1)
        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy,
            environment: fixture.environment
        )
        let clock = OverviewAnimationTestClock()
        let animator = OverviewAnimator(
            controller: overview,
            animationInstaller: { _, _, _ in true },
            mediaTimeProvider: { clock.time }
        )

        animator.startOpenAnimation(displayIds: [91_001])
        clock.time = 100

        XCTAssertEqual(animator.currentProgress, 1)
        XCTAssertEqual(animator.currentVelocity, 0)
        XCTAssertTrue(animator.isAnimating)
        XCTAssertEqual(animator.activeDisplayIds, [91_001])
        XCTAssertEqual(animator.completionCount, 0)

        animator.animationCompleted(displayId: 91_001, generation: animator.generation)

        XCTAssertEqual(animator.completionCount, 1)
    }

    func testAnimatorRecordsCaptureGatedNativeSubmissionAndCompletion() throws {
        let fixture = try makeRuntimeOverviewFixture(windowCount: 1)
        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy,
            environment: fixture.environment
        )
        let animator = OverviewAnimator(
            controller: overview,
            animationInstaller: { _, _, _ in true },
            mediaTimeProvider: { 0 }
        )
        let displayId: CGDirectDisplayID = 91_001
        OverviewFrameTrace.shared.beginCapture()
        animator.startOpenAnimation(displayIds: [displayId])
        let generation = animator.generation
        animator.animationCompleted(
            displayId: displayId,
            generation: generation
        )
        OverviewFrameTrace.shared.endCapture()

        let trace = OverviewFrameTrace.shared.dump()
        XCTAssertTrue(trace.contains("event=animationSubmit"))
        XCTAssertTrue(trace.contains("event=animationComplete"))
        XCTAssertTrue(trace.contains("disp=91001 gen=\(generation) seq=0"))
    }

    func testAnimatorPreservesProgressWhenOpeningRetargetsToClose() throws {
        let fixture = try makeRuntimeOverviewFixture(windowCount: 1)
        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy,
            environment: fixture.environment
        )
        let clock = OverviewAnimationTestClock()
        let animator = OverviewAnimator(
            controller: overview,
            animationInstaller: { _, _, _ in true },
            mediaTimeProvider: { clock.time }
        )
        let displayId: CGDirectDisplayID = 91_001

        animator.startOpenAnimation(displayIds: [displayId])
        clock.time = 0.03
        let openingProgress = animator.currentProgress

        animator.startCloseAnimation(targetWindow: nil, displayIds: [displayId])

        XCTAssertEqual(animator.currentProgress, openingProgress, accuracy: 0.000_000_1)
        XCTAssertEqual(animator.activeDisplayIds, [displayId])
    }

    func testAnimatorPreservesSharedSpringStateWhenClosingRetargetsToOpen() throws {
        let fixture = try makeRuntimeOverviewFixture(windowCount: 1)
        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy,
            environment: fixture.environment
        )
        let clock = OverviewAnimationTestClock()
        var startedSessions: [(CGDirectDisplayID, UInt64)] = []
        let animator = OverviewAnimator(
            controller: overview,
            animationInstaller: { displayId, transition, _ in
                startedSessions.append((displayId, transition.generation))
                return true
            },
            mediaTimeProvider: { clock.time }
        )
        let firstDisplayId: CGDirectDisplayID = 91_001
        let secondDisplayId: CGDirectDisplayID = 91_002

        animator.startCloseAnimation(
            targetWindow: fixture.handles[0],
            displayIds: [firstDisplayId, secondDisplayId]
        )
        let closingGeneration = animator.generation
        clock.time = 0.03
        let closingProgress = animator.currentProgress
        let closingVelocity = animator.currentVelocity

        animator.startOpenAnimation(displayIds: [firstDisplayId, secondDisplayId])
        let openingGeneration = animator.generation

        XCTAssertGreaterThan(openingGeneration, closingGeneration)
        XCTAssertEqual(animator.currentProgress, closingProgress, accuracy: 0.000_000_1)
        XCTAssertEqual(animator.currentVelocity, closingVelocity, accuracy: 0.000_000_1)
        XCTAssertEqual(animator.activeDisplayIds, [firstDisplayId, secondDisplayId])
        XCTAssertEqual(startedSessions.count, 4)
        XCTAssertEqual(Set(startedSessions.suffix(2).map(\.1)), [openingGeneration])

        animator.animationCompleted(
            displayId: firstDisplayId,
            generation: closingGeneration
        )
        XCTAssertEqual(animator.completionCount, 0)

        completeAnimator(animator, displayId: firstDisplayId, generation: openingGeneration)

        completeAnimator(animator, displayId: secondDisplayId, generation: openingGeneration)

        XCTAssertEqual(animator.completionCount, 1)
        XCTAssertEqual(animator.completedGeneration, openingGeneration)
        guard case .open = overview.state else {
            return XCTFail("Expected the reversed transition to finish opening")
        }

        animator.animationCompleted(
            displayId: secondDisplayId,
            generation: closingGeneration
        )
        XCTAssertEqual(animator.completionCount, 1)
    }

    @MainActor
    private struct InteractiveOverviewHarness {
        let fixture: RuntimeOverviewFixture
        let overview: OverviewController
        let clock: OverviewAnimationTestClock
        let handoffScheduler: OverviewPostCloseHandoffScheduler
        var installed: [OverviewNativeTransition] {
            storage.installed
        }

        var completions: [OverviewAnimationCompletion] {
            storage.completions
        }

        var activations: Int {
            storage.activations
        }

        var activatedPIDs: [pid_t] {
            storage.activatedPIDs
        }

        private let storage: Storage

        @MainActor
        final class Storage {
            var installed: [OverviewNativeTransition] = []
            var completions: [OverviewAnimationCompletion] = []
            var activations = 0
            var activatedPIDs: [pid_t] = []
        }

        init(fixture: RuntimeOverviewFixture, previousApplicationPID: pid_t? = nil) {
            fixture.controller.motionPolicy.animationsEnabled = true
            let storage = Storage()
            let clock = OverviewAnimationTestClock()
            let handoffScheduler = OverviewPostCloseHandoffScheduler()
            var environment = fixture.environment
            environment.frontmostApplicationPID = { previousApplicationPID }
            environment.activateOmniWM = { storage.activations += 1 }
            environment.activateApplication = { storage.activatedPIDs.append($0) }
            environment.schedulePostCloseHandoff = handoffScheduler.schedule
            overview = OverviewController(
                wmController: fixture.controller,
                motionPolicy: fixture.controller.motionPolicy,
                environment: environment,
                animationInstaller: { _, transition, completion in
                    storage.installed.append(transition)
                    storage.completions.append(completion)
                    return true
                },
                animationMediaTimeProvider: { clock.time }
            )
            self.fixture = fixture
            self.clock = clock
            self.handoffScheduler = handoffScheduler
            self.storage = storage
        }

        func completeLastTransition() throws {
            try XCTUnwrap(completions.last).complete()
        }
    }

    func testOpeningGestureTailCannotMoveOverviewBeforeFreshScroll() throws {
        let recorder = TrackpadScrollTrace.shared
        recorder.beginCapture()
        defer {
            recorder.endCapture()
            recorder.releaseStorage()
        }
        let fixture = try makeRuntimeOverviewFixture(windowCount: 1)
        let manager = fixture.controller.workspaceManager
        let monitorId = try XCTUnwrap(manager.monitors.first?.id)
        let empty = try XCTUnwrap(manager.workspaceId(for: "2", createIfMissing: true))
        manager.assignWorkspaceToMonitor(empty, monitorId: monitorId)
        let harness = InteractiveOverviewHarness(fixture: fixture)
        let overview = harness.overview
        defer { overview.completeCloseTransition(targetWindow: nil) }

        XCTAssertTrue(overview.beginInteractiveTransition())
        overview.updateInteractiveTransition(cumulativeUnits: 20, timestamp: 100)
        overview.updateInteractiveTransition(cumulativeUnits: 170, timestamp: 100.1)
        harness.clock.time = 100.1
        overview.endInteractiveTransition(timestamp: 100.1)
        guard case .opening = overview.state else { return XCTFail("Expected release animation") }
        XCTAssertFalse(overview.isInteractiveTransitionActive)

        let view = try XCTUnwrap(overview.windowSession.primaryOverviewWindow()?.contentView?.subviews
            .compactMap { $0 as? OverviewView }.first)
        let offset = view.layout.scrollOffset
        let selected = overview.selectedWindowHandle
        let active = manager.activeWorkspace(on: monitorId)?.id
        var event = OverviewScrollInput.Event(
            deltaX: 15, deltaY: -60, modifiers: [], isPrecise: true, location: .zero, phase: .began
        )
        for phase: NSEvent.Phase in [.began, .ended] {
            event.phase = phase
            overview.input.handleScroll(event, on: monitorId)
            XCTAssertEqual(view.layout.scrollOffset, offset)
            XCTAssertEqual(overview.selectedWindowHandle, selected)
            XCTAssertEqual(manager.activeWorkspace(on: monitorId)?.id, active)
        }
        try harness.completeLastTransition()
        event.phase = []
        for phase: NSEvent.Phase in [.began, .changed, .ended] {
            event.momentumPhase = phase
            overview.input.handleScroll(event, on: monitorId)
            XCTAssertEqual(view.layout.scrollOffset, offset)
        }
        event.momentumPhase = []
        event.phase = .began
        overview.input.handleScroll(event, on: monitorId)
        XCTAssertNotEqual(view.layout.scrollOffset, offset)
        XCTAssertEqual(overview.selectedWindowHandle, selected)
        XCTAssertEqual(manager.activeWorkspace(on: monitorId)?.id, active)
        let trace = recorder.dump()
        XCTAssertTrue(trace.contains("overview-scroll phase=1 momentum=0 precise=true state=opening suppressed=true"))
        XCTAssertTrue(trace.contains("overview-scroll phase=1 momentum=0 precise=true state=open suppressed=false"))
    }

    func testKeyboardOverviewOpeningAndReopeningAllowPreciseScrolling() throws {
        let harness = try InteractiveOverviewHarness(fixture: makeRuntimeOverviewFixture(windowCount: 1))
        let overview = harness.overview
        let manager = harness.fixture.controller.workspaceManager
        let monitorId = try XCTUnwrap(manager.monitors.first?.id)
        let empty = try XCTUnwrap(manager.workspaceId(for: "2", createIfMissing: true))
        manager.assignWorkspaceToMonitor(empty, monitorId: monitorId)
        defer { overview.completeCloseTransition(targetWindow: nil) }
        let event = OverviewScrollInput.Event(
            deltaX: 0, deltaY: -60, modifiers: [], isPrecise: true, location: .zero, phase: .changed
        )
        for _ in 0 ..< 2 {
            overview.toggle()
            guard case .opening = overview.state else { return XCTFail("Expected keyboard opening") }
            let view = try XCTUnwrap(overview.windowSession.primaryOverviewWindow()?.contentView?.subviews
                .compactMap { $0 as? OverviewView }.first)
            let offset = view.layout.scrollOffset
            overview.input.handleScroll(event, on: monitorId)
            XCTAssertNotEqual(view.layout.scrollOffset, offset)
            overview.input.beginGestureScrollSuppression()
            overview.completeCloseTransition(targetWindow: nil)
        }
    }

    func testInteractiveOpenTracksFingerAndCommitsWithVelocity() throws {
        let harness = try InteractiveOverviewHarness(fixture: makeRuntimeOverviewFixture(windowCount: 1))
        let overview = harness.overview

        XCTAssertTrue(overview.beginInteractiveTransition())
        guard case .opening = overview.state else { return XCTFail("Expected tracking to live in .opening") }
        XCTAssertTrue(overview.isInteractiveTransitionActive)
        XCTAssertEqual(harness.activations, 0)
        XCTAssertTrue(harness.installed.isEmpty)

        overview.updateInteractiveTransition(cumulativeUnits: 20, timestamp: 100)
        XCTAssertEqual(overview.transitionProgress, 0, accuracy: 0.000000000001)
        overview.updateInteractiveTransition(cumulativeUnits: 170, timestamp: 100.1)
        XCTAssertEqual(overview.transitionProgress, 0.5, accuracy: 0.000000000001)
        XCTAssertTrue(harness.installed.isEmpty)
        XCTAssertEqual(harness.activations, 0)

        harness.clock.time = 100.1
        overview.endInteractiveTransition(timestamp: 100.1)

        XCTAssertFalse(overview.isInteractiveTransitionActive)
        XCTAssertEqual(harness.activations, 1)
        XCTAssertEqual(harness.installed.count, 1)
        let transition = try XCTUnwrap(harness.installed.last)
        XCTAssertEqual(transition.from, 0.5, accuracy: 0.000000000001)
        XCTAssertEqual(transition.target, 1)
        XCTAssertEqual(transition.initialVelocity, 5, accuracy: 0.000000001)
        XCTAssertEqual(
            transition.response,
            OverviewNativeTransition.compressedResponse(forReleaseVelocity: 5),
            accuracy: 0.000000000001
        )
        XCTAssertEqual(transition.startTime, 100.1)
        XCTAssertEqual(overview.transitionProgress, 0.5, accuracy: 0.000000000001)

        try harness.completeLastTransition()
        guard case .open = overview.state else { return XCTFail("Expected the committed spring to open") }
        overview.completeCloseTransition(targetWindow: nil)
    }

    func testReflowCloseGestureReturningOpenRestoresCanonicalEndpointBeforeCompletion() throws {
        let harness = try InteractiveOverviewHarness(fixture: makeRuntimeOverviewFixture(windowCount: 1))
        let overview = harness.overview
        overview.open()
        defer { overview.completeCloseTransition(targetWindow: nil) }
        harness.clock.time = 10
        try harness.completeLastTransition()
        let panel = try XCTUnwrap(overview.windowSession.primaryOverviewWindow())
        let view = try XCTUnwrap(panel.contentView?.subviews.compactMap { $0 as? OverviewView }.first)
        let handle = try XCTUnwrap(overview.selectedWindowHandle)
        let canonical = view.layout
        let target = try XCTUnwrap(canonical.window(for: handle)).overviewFrame
        var displaced = canonical
        displaced.replaceWorkspaceSections(canonical.workspaceSections.map { section in
            var section = section
            for index in section.windows.indices {
                section.windows[index].overviewFrame = section.windows[index].overviewFrame.offsetBy(dx: -150, dy: 0)
            }
            return section
        })
        view.updateLayout(displaced, state: .open, searchQuery: "", selectedWindowHandle: handle, update: .immediate)
        view.updateLayer()
        view.updateLayout(canonical, state: .open, searchQuery: "", selectedWindowHandle: handle, update: .structural)
        let displayed = try XCTUnwrap(view.layerRenderer.windowLayers[handle]).displayedFrame
        XCTAssertTrue(view.layerRenderer.isReflowing)

        XCTAssertTrue(overview.beginInteractiveTransition())
        XCTAssertEqual(view.layout.window(for: handle)?.overviewFrame, displayed)
        overview.updateInteractiveTransition(cumulativeUnits: 0, timestamp: 10)
        overview.updateInteractiveTransition(cumulativeUnits: -60, timestamp: 10.1)
        harness.clock.time = 10.6
        overview.endInteractiveTransition(timestamp: 10.6)

        XCTAssertEqual(harness.installed.last?.target, 1)
        XCTAssertEqual(view.layout.window(for: handle)?.overviewFrame, target)
        try harness.completeLastTransition()
        view.updateLayer()
        XCTAssertEqual(view.layerRenderer.windowLayers[handle]?.root.frame, target)
    }

    func testRegisteredReturnDuringOpeningUsesExistingSelectionDismissal() throws {
        let harness = try InteractiveOverviewHarness(fixture: makeRuntimeOverviewFixture(windowCount: 1))
        let overview = harness.overview
        overview.open()
        defer { overview.completeCloseTransition(targetWindow: nil) }
        let selected = overview.selectedWindowHandle
        let disposition = overview.input.handleHotkeyInvocation(HotkeyInvocation(
            command: .focus(.left),
            trigger: PhysicalHotkeyTrigger(keyCode: UInt32(kVK_Return), modifiers: 0, isRepeat: false)
        ))
        XCTAssertEqual(disposition, .handled)
        guard case let .closing(targetWindow) = overview.state else { return XCTFail("Expected opening reversal") }
        XCTAssertEqual(targetWindow, selected)
    }

    func testInteractiveOpenCancelsBelowHalfAndRestoresPreviousApplication() throws {
        let harness = try InteractiveOverviewHarness(
            fixture: makeRuntimeOverviewFixture(windowCount: 1),
            previousApplicationPID: 91_900
        )
        let overview = harness.overview

        XCTAssertTrue(overview.beginInteractiveTransition())
        overview.updateInteractiveTransition(cumulativeUnits: 20, timestamp: 100)
        overview.updateInteractiveTransition(cumulativeUnits: 110, timestamp: 100.5)
        XCTAssertEqual(overview.transitionProgress, 0.3, accuracy: 0.000000000001)

        harness.clock.time = 100.9
        overview.endInteractiveTransition(timestamp: 100.9)

        guard case let .closing(target) = overview.state else { return XCTFail("Expected release below half to close") }
        XCTAssertNil(target)
        XCTAssertFalse(overview.isInteractiveTransitionActive)
        XCTAssertEqual(harness.activations, 0)
        let transition = try XCTUnwrap(harness.installed.last)
        XCTAssertEqual(harness.installed.count, 1)
        XCTAssertEqual(transition.from, 0.3, accuracy: 0.000000000001)
        XCTAssertEqual(transition.target, 0)
        XCTAssertEqual(transition.initialVelocity, 0)
        XCTAssertEqual(transition.response, 0.25)

        try harness.completeLastTransition()
        XCTAssertFalse(overview.state.isOpen)
        XCTAssertEqual(harness.handoffScheduler.count, 1)
        harness.handoffScheduler.runNext()
        XCTAssertEqual(harness.activatedPIDs, [91_900])
    }

    func testInteractiveCloseFromOpenTracksInOpeningAndKeepsSelectionHandoff() throws {
        let harness = try InteractiveOverviewHarness(fixture: makeRuntimeOverviewFixture(windowCount: 1))
        let overview = harness.overview
        overview.open()
        XCTAssertEqual(harness.activations, 1)
        harness.clock.time = 10
        try harness.completeLastTransition()
        let selectedHandle = try XCTUnwrap(overview.selectedWindowHandle)
        var activatedHandles: [WindowHandle] = []
        overview.onActivateWindow = { handle, _ in activatedHandles.append(handle) }

        XCTAssertTrue(overview.beginInteractiveTransition())
        guard case .opening = overview.state else { return XCTFail("Expected a close-track to live in .opening") }
        XCTAssertEqual(overview.transitionProgress, 1)
        XCTAssertEqual(harness.installed.count, 1)
        overview.updateInteractiveTransition(cumulativeUnits: 0, timestamp: 10)
        overview.updateInteractiveTransition(cumulativeUnits: -240, timestamp: 10.1)
        XCTAssertEqual(overview.transitionProgress, 0.2, accuracy: 0.000000000001)

        harness.clock.time = 10.6
        overview.endInteractiveTransition(timestamp: 10.6)

        guard case let .closing(target) = overview.state else { return XCTFail("Expected release below half to close") }
        XCTAssertEqual(target, selectedHandle)
        XCTAssertEqual(harness.installed.count, 2)
        let transition = try XCTUnwrap(harness.installed.last)
        XCTAssertEqual(transition.from, 0.2, accuracy: 0.000000000001)
        XCTAssertEqual(transition.target, 0)
        XCTAssertEqual(transition.initialVelocity, 0)
        XCTAssertEqual(harness.activations, 1)

        try harness.completeLastTransition()
        XCTAssertFalse(overview.state.isOpen)
        XCTAssertEqual(harness.handoffScheduler.count, 1)
        harness.handoffScheduler.runNext()
        XCTAssertEqual(activatedHandles, [selectedHandle])
    }

    func testUpwardFlickDuringCloseTrackReopens() throws {
        let harness = try InteractiveOverviewHarness(fixture: makeRuntimeOverviewFixture(windowCount: 1))
        let overview = harness.overview
        overview.open()
        harness.clock.time = 10
        try harness.completeLastTransition()

        XCTAssertTrue(overview.beginInteractiveTransition())
        overview.updateInteractiveTransition(cumulativeUnits: 0, timestamp: 10)
        overview.updateInteractiveTransition(cumulativeUnits: -150, timestamp: 10.1)
        overview.updateInteractiveTransition(cumulativeUnits: -120, timestamp: 10.3)
        XCTAssertEqual(overview.transitionProgress, 0.6, accuracy: 0.000000000001)
        harness.clock.time = 10.32
        overview.endInteractiveTransition(timestamp: 10.32)

        guard case .opening = overview.state else { return XCTFail("Expected an upward flick to reopen") }
        XCTAssertEqual(harness.activations, 2)
        let transition = try XCTUnwrap(harness.installed.last)
        XCTAssertEqual(harness.installed.count, 2)
        XCTAssertEqual(transition.target, 1)
        XCTAssertEqual(transition.from, 0.6, accuracy: 0.000000000001)
        XCTAssertEqual(transition.initialVelocity, 5, accuracy: 0.000000001)

        try harness.completeLastTransition()
        guard case .open = overview.state else { return XCTFail("Expected the reopened spring to settle open") }
        overview.completeCloseTransition(targetWindow: nil)
    }

    func testTouchDownDuringFlightFreezesAtAnalyticProgressAndReanchors() throws {
        let harness = try InteractiveOverviewHarness(fixture: makeRuntimeOverviewFixture(windowCount: 1))
        let overview = harness.overview
        overview.open()
        XCTAssertEqual(harness.installed.count, 1)
        let flight = try XCTUnwrap(harness.installed.first)
        harness.clock.time = 0.05
        let caught = flight.value(at: 0.05)
        XCTAssertGreaterThan(caught, 0)
        XCTAssertLessThan(caught, 0.5)

        XCTAssertTrue(overview.beginInteractiveTransition())

        XCTAssertEqual(harness.installed.count, 1)
        XCTAssertTrue(overview.isInteractiveTransitionActive)
        XCTAssertEqual(overview.transitionProgress, caught, accuracy: 0.000000000001)
        guard case .opening = overview.state else { return XCTFail("Expected the caught flight to stay in .opening") }
        try XCTUnwrap(harness.completions.first).complete()
        XCTAssertTrue(overview.isInteractiveTransitionActive)
        guard case .opening = overview.state else { return XCTFail("Expected a stale completion to be ignored") }

        overview.updateInteractiveTransition(cumulativeUnits: 100, timestamp: 0.05)
        XCTAssertEqual(overview.transitionProgress, caught, accuracy: 0.000000000001)
        overview.updateInteractiveTransition(cumulativeUnits: 130, timestamp: 0.1)
        XCTAssertEqual(overview.transitionProgress, caught + 0.1, accuracy: 0.000000000001)

        harness.clock.time = 0.1
        overview.endInteractiveTransition(timestamp: 0.1)

        XCTAssertEqual(harness.installed.count, 2)
        let transition = try XCTUnwrap(harness.installed.last)
        XCTAssertEqual(transition.from, caught + 0.1, accuracy: 0.000000000001)
        XCTAssertEqual(transition.target, 1)
        XCTAssertEqual(transition.initialVelocity, 2, accuracy: 0.000000001)
        try harness.completeLastTransition()
        guard case .open = overview.state else { return XCTFail("Expected the resumed flight to open") }
        overview.completeCloseTransition(targetWindow: nil)
    }

    func testTapDuringFlightThenLiftResolvesByPosition() throws {
        for late in [false, true] {
            let harness = try InteractiveOverviewHarness(
                fixture: makeRuntimeOverviewFixture(windowCount: 1),
                previousApplicationPID: 91_900
            )
            let overview = harness.overview
            overview.open()
            harness.clock.time = late ? 0.3 : 0.05
            let caught = try XCTUnwrap(harness.installed.first).value(at: harness.clock.time)

            XCTAssertTrue(overview.beginInteractiveTransition())
            XCTAssertEqual(harness.installed.count, 1)
            overview.endInteractiveTransition(timestamp: nil)

            XCTAssertFalse(overview.isInteractiveTransitionActive)
            XCTAssertEqual(harness.installed.count, 2)
            let transition = try XCTUnwrap(harness.installed.last)
            XCTAssertEqual(transition.from, caught, accuracy: 0.000000000001)
            XCTAssertEqual(transition.initialVelocity, 0)
            if late {
                guard case .opening = overview.state else { return XCTFail("Expected a late tap to resume opening") }
                XCTAssertEqual(transition.target, 1)
                XCTAssertEqual(harness.activations, 2)
                try harness.completeLastTransition()
                overview.completeCloseTransition(targetWindow: nil)
            } else {
                guard case let .closing(target) = overview.state else {
                    return XCTFail("Expected an early tap to close")
                }
                XCTAssertNil(target)
                XCTAssertEqual(transition.target, 0)
                XCTAssertEqual(harness.activations, 1)
                try harness.completeLastTransition()
                XCTAssertEqual(harness.handoffScheduler.count, 1)
                harness.handoffScheduler.runNext()
                XCTAssertEqual(harness.activatedPIDs, [91_900])
            }
        }
    }

    func testCaughtCancelledCloseReleasedBelowHalfStaysACancel() throws {
        let harness = try InteractiveOverviewHarness(
            fixture: makeRuntimeOverviewFixture(windowCount: 1),
            previousApplicationPID: 91_900
        )
        let overview = harness.overview
        var activatedHandles: [WindowHandle] = []
        overview.onActivateWindow = { handle, _ in activatedHandles.append(handle) }
        XCTAssertTrue(overview.beginInteractiveTransition())
        overview.updateInteractiveTransition(cumulativeUnits: 0, timestamp: 100)
        overview.updateInteractiveTransition(cumulativeUnits: 75, timestamp: 100.5)
        harness.clock.time = 100.9
        overview.endInteractiveTransition(timestamp: 100.9)
        guard case .closing = overview.state else { return XCTFail("Expected the short swipe to cancel") }

        harness.clock.time = 100.95
        XCTAssertTrue(overview.beginInteractiveTransition())
        guard case .opening = overview.state else { return XCTFail("Expected the catch to track in .opening") }
        overview.endInteractiveTransition(timestamp: nil)

        guard case let .closing(target) = overview.state else { return XCTFail("Expected the lift to close again") }
        XCTAssertNil(target)
        XCTAssertEqual(harness.activations, 0)
        try harness.completeLastTransition()
        XCTAssertFalse(overview.state.isOpen)
        XCTAssertEqual(harness.handoffScheduler.count, 1)
        harness.handoffScheduler.runNext()
        XCTAssertEqual(harness.activatedPIDs, [91_900])
        XCTAssertTrue(activatedHandles.isEmpty)
    }

    func testCaughtExternalDeactivationCloseKeepsFocusWithTheForegroundApp() throws {
        let harness = try InteractiveOverviewHarness(fixture: makeRuntimeOverviewFixture(windowCount: 1))
        let overview = harness.overview
        var activatedHandles: [WindowHandle] = []
        overview.onActivateWindow = { handle, _ in activatedHandles.append(handle) }
        overview.open()
        harness.clock.time = 10
        try harness.completeLastTransition()
        overview.dismiss(reason: .externalDeactivation, animated: true)
        harness.clock.time = 10.15
        let caught = try XCTUnwrap(harness.installed.last).value(at: 10.15)
        XCTAssertLessThan(caught, 0.5)

        XCTAssertTrue(overview.beginInteractiveTransition())
        XCTAssertEqual(overview.transitionProgress, caught, accuracy: 0.000000000001)
        overview.endInteractiveTransition(timestamp: nil)

        guard case let .closing(target) = overview.state else { return XCTFail("Expected the lift to close again") }
        XCTAssertNil(target)
        try harness.completeLastTransition()
        XCTAssertFalse(overview.state.isOpen)
        XCTAssertEqual(harness.handoffScheduler.count, 0)
        XCTAssertTrue(activatedHandles.isEmpty)
    }

    func testToggleWhileTrackingDecidesByProgress() throws {
        for aboveHalf in [false, true] {
            let harness = try InteractiveOverviewHarness(fixture: makeRuntimeOverviewFixture(windowCount: 1))
            let overview = harness.overview
            XCTAssertTrue(overview.beginInteractiveTransition())
            let selectedHandle = try XCTUnwrap(overview.selectedWindowHandle)
            overview.updateInteractiveTransition(cumulativeUnits: 20, timestamp: 100)
            overview.updateInteractiveTransition(cumulativeUnits: aboveHalf ? 230 : 50, timestamp: 100.1)
            harness.clock.time = 100.1

            overview.toggle()

            XCTAssertFalse(overview.isInteractiveTransitionActive)
            XCTAssertEqual(harness.installed.count, 1)
            let transition = try XCTUnwrap(harness.installed.last)
            XCTAssertEqual(transition.from, aboveHalf ? 0.7 : 0.1, accuracy: 0.000000000001)
            overview.updateInteractiveTransition(cumulativeUnits: 300, timestamp: 100.2)
            XCTAssertEqual(overview.transitionProgress, transition.from, accuracy: 0.000000000001)
            if aboveHalf {
                guard case let .closing(target) = overview.state else {
                    return XCTFail("Expected the hotkey above half to close")
                }
                XCTAssertEqual(target, selectedHandle)
                XCTAssertEqual(transition.target, 0)
                XCTAssertEqual(harness.activations, 0)
                try harness.completeLastTransition()
            } else {
                guard case .opening = overview.state else { return XCTFail("Expected the hotkey below half to open") }
                XCTAssertEqual(transition.target, 1)
                XCTAssertEqual(harness.activations, 1)
                try harness.completeLastTransition()
                overview.completeCloseTransition(targetWindow: nil)
            }
        }
    }

    func testExternalDismissDuringTrackingHandsOffTrackedProgress() throws {
        let harness = try InteractiveOverviewHarness(fixture: makeRuntimeOverviewFixture(windowCount: 1))
        let overview = harness.overview
        XCTAssertTrue(overview.beginInteractiveTransition())
        overview.updateInteractiveTransition(cumulativeUnits: 20, timestamp: 100)
        overview.updateInteractiveTransition(cumulativeUnits: 110, timestamp: 100.5)
        harness.clock.time = 100.5

        overview.dismiss(reason: .externalDeactivation, animated: true)

        XCTAssertFalse(overview.isInteractiveTransitionActive)
        guard case .closing = overview.state else { return XCTFail("Expected external deactivation to close") }
        let transition = try XCTUnwrap(harness.installed.last)
        XCTAssertEqual(harness.installed.count, 1)
        XCTAssertEqual(transition.from, 0.3, accuracy: 0.000000000001)
        XCTAssertEqual(transition.target, 0)
        overview.updateInteractiveTransition(cumulativeUnits: 300, timestamp: 100.6)
        XCTAssertEqual(overview.transitionProgress, 0.3, accuracy: 0.000000000001)
        try harness.completeLastTransition()
        XCTAssertFalse(overview.state.isOpen)
    }

    func testInteractiveTransitionUnavailableWithoutAnimations() throws {
        let fixture = try makeRuntimeOverviewFixture(windowCount: 1)
        var activations = 0
        var environment = fixture.environment
        environment.activateOmniWM = { activations += 1 }
        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy,
            environment: environment,
            animationInstaller: { _, _, _ in XCTFail("Unexpected install")
                return true
            },
            animationMediaTimeProvider: { 0 }
        )

        XCTAssertFalse(overview.beginInteractiveTransition())

        XCTAssertFalse(overview.state.isOpen)
        XCTAssertFalse(overview.isInteractiveTransitionActive)
        XCTAssertEqual(activations, 0)
    }

    func testOverscrollReleaseSnapsBackToOpen() throws {
        let harness = try InteractiveOverviewHarness(fixture: makeRuntimeOverviewFixture(windowCount: 1))
        let overview = harness.overview
        XCTAssertTrue(overview.beginInteractiveTransition())
        overview.updateInteractiveTransition(cumulativeUnits: 0, timestamp: 100)
        overview.updateInteractiveTransition(cumulativeUnits: 330, timestamp: 100.1)
        XCTAssertEqual(overview.transitionProgress, 1.0464788732394366, accuracy: 0.000000000001)
        harness.clock.time = 100.1

        overview.endInteractiveTransition(timestamp: 100.1)

        guard case .opening = overview.state else { return XCTFail("Expected an overscroll release to open") }
        let transition = try XCTUnwrap(harness.installed.last)
        XCTAssertEqual(harness.installed.count, 1)
        XCTAssertEqual(transition.from, 1.0464788732394366, accuracy: 0.000000000001)
        XCTAssertEqual(transition.target, 1)
        XCTAssertEqual(harness.activations, 1)
        try harness.completeLastTransition()
        guard case .open = overview.state else { return XCTFail("Expected the snap-back to settle open") }
        overview.completeCloseTransition(targetWindow: nil)
    }

    func testToggleDuringClosingReversesOverviewToOpening() throws {
        let fixture = try makeRuntimeOverviewFixture(windowCount: 1)
        fixture.controller.motionPolicy.animationsEnabled = true
        let clock = OverviewAnimationTestClock()
        var environment = fixture.environment
        environment.frontmostApplicationPID = { nil }
        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy,
            environment: environment,
            animationInstaller: { _, _, _ in true },
            animationMediaTimeProvider: { clock.time }
        )
        overview.open()
        clock.time = 10
        overview.onAnimationComplete(state: .open)

        overview.toggle()
        guard case .closing = overview.state else {
            return XCTFail("Expected toggle from open to begin closing")
        }

        clock.time = 10.03
        overview.toggle()

        guard case .opening = overview.state else {
            return XCTFail("Expected toggle during close to reverse into opening")
        }
        overview.completeCloseTransition(targetWindow: nil)
    }

    func testImmediateSelectionDismissDoesNotRecloseReversedOverview() async throws {
        let fixture = try makeRuntimeOverviewFixture(windowCount: 1)
        let harness = InteractiveOverviewHarness(fixture: fixture)
        let overview = harness.overview
        overview.open()
        harness.clock.time = 10
        try harness.completeLastTransition()
        let selectedHandle = try XCTUnwrap(overview.selectedWindowHandle)

        overview.input.selectAndActivateWindow(selectedHandle)
        guard case let .closing(target) = overview.state else {
            return XCTFail("Expected selection to close synchronously")
        }
        XCTAssertTrue(target === selectedHandle)
        harness.clock.time = 10.03
        overview.toggle()
        await Task.yield()
        await Task.yield()

        guard case .opening = overview.state else {
            return XCTFail("Expected reversal to remain opening")
        }
        XCTAssertEqual(harness.handoffScheduler.count, 0)
        XCTAssertEqual(harness.installed.count, 3)
        try harness.completeLastTransition()
        guard case .open = overview.state else { return XCTFail("Expected reversal to complete open") }
        overview.completeCloseTransition(targetWindow: nil)
    }

    func testImmediateSelectionDismissKeepsPressedHandle() throws {
        let fixture = try makeRuntimeOverviewFixture(windowCount: 2)
        let harness = InteractiveOverviewHarness(fixture: fixture)
        let overview = harness.overview
        overview.open()
        harness.clock.time = 10
        try harness.completeLastTransition()
        let originalSelection = try XCTUnwrap(overview.selectedWindowHandle)
        let view = try XCTUnwrap(overview.windowSession.primaryOverviewWindow()?.contentView?.subviews
            .compactMap { $0 as? OverviewView }.first)
        let pressedHandle = try XCTUnwrap(view.layout.allWindows.first { $0.handle !== originalSelection }?.handle)
        var activatedHandles: [WindowHandle] = []
        overview.onActivateWindow = { handle, _ in activatedHandles.append(handle) }

        overview.input.selectAndActivateWindow(pressedHandle)
        overview.input.cycleSelection(forward: true)

        guard case let .closing(target) = overview.state else {
            return XCTFail("Expected selection to close synchronously")
        }
        XCTAssertTrue(target === pressedHandle)
        XCTAssertTrue(overview.selectedWindowHandle === pressedHandle)
        XCTAssertTrue(activatedHandles.isEmpty)
        try harness.completeLastTransition()
        harness.handoffScheduler.runNext()
        XCTAssertEqual(activatedHandles, [pressedHandle])
    }

    func testInactiveWorkspaceSelectionPreparesBeforeCloseAndPreservesHandoff() async throws {
        for reducedMotion in [false, true] {
            let fixture = try makeRuntimeOverviewFixture(windowCount: 1, secondWorkspaceWindowCount: 1)
            let manager = fixture.controller.workspaceManager
            let destination = try XCTUnwrap(fixture.secondWorkspaceId)
            let monitor = try XCTUnwrap(manager.monitors.first)
            let harness = InteractiveOverviewHarness(fixture: fixture)
            fixture.controller.motionPolicy.systemReducesMotion = reducedMotion
            let overview = harness.overview
            var preparedHandles: [WindowHandle] = []
            var activatedHandles: [WindowHandle] = []
            overview.onPrepareActivation = { [weak overview] handle, workspaceId in
                XCTAssertFalse(overview?.state.isAnimating ?? true)
                preparedHandles.append(handle)
                fixture.controller.windowActionHandler.prepareOverviewSelection(
                    handle: handle,
                    workspaceId: workspaceId
                )
            }
            overview.onActivateWindow = { handle, _ in activatedHandles.append(handle) }
            overview.open()
            if !reducedMotion {
                harness.clock.time = 10
                try harness.completeLastTransition()
            }
            let view = try XCTUnwrap(overview.windowSession.primaryOverviewWindow()?.contentView?.subviews
                .compactMap { $0 as? OverviewView }.first)
            let target = try XCTUnwrap(view.layout.allWindows.first { $0.workspaceId == destination }?.handle)
            let watermark = fixture.controller.intentLedger.newestFocusIntentId()

            overview.input.selectAndActivateWindow(target)

            XCTAssertEqual(preparedHandles, [target])
            XCTAssertEqual(manager.activeWorkspace(on: monitor.id)?.id, destination)
            XCTAssertEqual(fixture.controller.intentLedger.newestFocusIntentId(), watermark)
            XCTAssertTrue(activatedHandles.isEmpty)
            if reducedMotion {
                guard case .closed = overview.state else { return XCTFail("Expected discrete close") }
                XCTAssertTrue(harness.installed.isEmpty)
            } else {
                guard case .closing = overview.state else { return XCTFail("Expected synchronous close") }
                XCTAssertEqual(view.layout.anchorWorkspaceId, destination)
            }
            let refresh = fixture.controller.layoutRefreshController
            while let task = refresh.layoutState.activeRefreshTask {
                await task.value
            }
            XCTAssertNil(refresh.layoutState.pendingRefresh)
            XCTAssertEqual(fixture.controller.intentLedger.newestFocusIntentId(), watermark)
            XCTAssertTrue(activatedHandles.isEmpty)
            if !reducedMotion {
                guard case .closing = overview.state else { return XCTFail("Relayout must preserve close") }
                try harness.completeLastTransition()
            }
            XCTAssertEqual(harness.handoffScheduler.count, 1)
            harness.handoffScheduler.runNext()
            XCTAssertEqual(activatedHandles, [target])
        }
    }

    func testCrossWorkspaceCloseReversalKeepsPreparedWorkspaceActive() async throws {
        let fixture = try makeRuntimeOverviewFixture(windowCount: 1, secondWorkspaceWindowCount: 1)
        let harness = InteractiveOverviewHarness(fixture: fixture)
        let overview = harness.overview
        let manager = fixture.controller.workspaceManager
        let monitor = try XCTUnwrap(manager.monitors.first)
        let destination = try XCTUnwrap(fixture.secondWorkspaceId)
        overview.onPrepareActivation = fixture.controller.windowActionHandler.prepareOverviewSelection
        overview.open()
        harness.clock.time = 10
        try harness.completeLastTransition()
        let view = try XCTUnwrap(overview.windowSession.primaryOverviewWindow()?.contentView?.subviews
            .compactMap { $0 as? OverviewView }.first)
        let target = try XCTUnwrap(view.layout.allWindows.first { $0.workspaceId == destination }?.handle)

        overview.input.selectAndActivateWindow(target)
        harness.clock.time = 10.03
        overview.toggle()

        guard case .opening = overview.state else { return XCTFail("Expected close reversal") }
        XCTAssertEqual(manager.activeWorkspace(on: monitor.id)?.id, destination)
        XCTAssertEqual(view.layout.anchorWorkspaceId, destination)
        XCTAssertEqual(overview.selectedWindowHandle, target)
        XCTAssertEqual(harness.handoffScheduler.count, 0)
        while let task = fixture.controller.layoutRefreshController.layoutState.activeRefreshTask { await task.value }
        try harness.completeLastTransition()
        overview.completeCloseTransition(targetWindow: nil)
    }

    func testCrossWorkspaceGesturePreparesOnlyWhenCloseCommits() async throws {
        let fixture = try makeRuntimeOverviewFixture(windowCount: 1, secondWorkspaceWindowCount: 1)
        let harness = InteractiveOverviewHarness(fixture: fixture)
        let overview = harness.overview
        let manager = fixture.controller.workspaceManager
        let monitor = try XCTUnwrap(manager.monitors.first)
        let destination = try XCTUnwrap(fixture.secondWorkspaceId)
        overview.onPrepareActivation = fixture.controller.windowActionHandler.prepareOverviewSelection
        overview.open()
        harness.clock.time = 10
        try harness.completeLastTransition()
        let view = try XCTUnwrap(overview.windowSession.primaryOverviewWindow()?.contentView?.subviews
            .compactMap { $0 as? OverviewView }.first)
        let target = try XCTUnwrap(view.layout.allWindows.first { $0.workspaceId == destination }?.handle)
        if overview.selectedWindowHandle !== target { overview.input.cycleSelection(forward: true) }
        XCTAssertEqual(overview.selectedWindowHandle, target)
        XCTAssertTrue(overview.beginInteractiveTransition())
        overview.updateInteractiveTransition(cumulativeUnits: 0, timestamp: 10)
        overview.updateInteractiveTransition(cumulativeUnits: -240, timestamp: 10.1)
        XCTAssertEqual(manager.activeWorkspace(on: monitor.id)?.id, fixture.workspaceId)
        XCTAssertEqual(view.layout.anchorWorkspaceId, fixture.workspaceId)

        harness.clock.time = 10.6
        overview.endInteractiveTransition(timestamp: 10.6)

        guard case let .closing(selected) = overview.state else { return XCTFail("Expected committed gesture close") }
        XCTAssertEqual(selected, target)
        XCTAssertEqual(manager.activeWorkspace(on: monitor.id)?.id, destination)
        XCTAssertEqual(view.layout.anchorWorkspaceId, destination)
        XCTAssertEqual(harness.installed.last?.from ?? -1, 0.2, accuracy: 0.000000001)
        XCTAssertEqual(harness.installed.last?.target, 0)
        while let task = fixture.controller.layoutRefreshController.layoutState.activeRefreshTask { await task.value }
        try harness.completeLastTransition()
    }

    func testRestAnchorsFollowEachMonitorsActiveWorkspace() async throws {
        let fixture = try makeRuntimeOverviewFixture(windowCount: 1, secondWorkspaceWindowCount: 1)
        let manager = fixture.controller.workspaceManager
        let firstMonitor = try XCTUnwrap(manager.monitors.first)
        let otherMonitor = Monitor(
            id: .init(displayId: 91_002),
            displayId: 91_002,
            frame: screenFrame.offsetBy(dx: 1000, dy: 200),
            visibleFrame: screenFrame.offsetBy(dx: 1000, dy: 200),
            hasNotch: false,
            name: "Other Overview"
        )
        fixture.controller.settings.workspaces.configurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main, layoutType: .niri),
            WorkspaceConfiguration(name: "2", monitorAssignment: .main, layoutType: .niri),
            WorkspaceConfiguration(
                name: "3",
                monitorAssignment: .specificDisplay(OutputId(from: otherMonitor)),
                layoutType: .niri
            )
        ]
        manager.applyMonitorConfigurationChange([firstMonitor, otherMonitor])
        manager.applySettings()
        fixture.controller.syncMonitorsToNiriEngine()
        let destination = try XCTUnwrap(fixture.secondWorkspaceId)
        manager.assignWorkspaceToMonitor(fixture.workspaceId, monitorId: firstMonitor.id)
        manager.assignWorkspaceToMonitor(destination, monitorId: firstMonitor.id)
        let otherWorkspace = try XCTUnwrap(manager.workspaceId(for: "3", createIfMissing: true))
        manager.assignWorkspaceToMonitor(otherWorkspace, monitorId: otherMonitor.id)
        XCTAssertTrue(manager.setActiveWorkspace(fixture.workspaceId, on: firstMonitor.id))
        XCTAssertTrue(manager.setActiveWorkspace(otherWorkspace, on: otherMonitor.id))
        let snapshot = OverviewSnapshot(
            wmController: fixture.controller,
            facts: OverviewWindowFacts(wmController: fixture.controller, environment: fixture.environment)
        )
        snapshot.build()
        let projection = OverviewViewportProjection(wmController: fixture.controller, snapshot: snapshot, scale: 1)
        projection.rebuildProjectedLayouts()
        let target = try XCTUnwrap(snapshot.windows.first { $0.value.workspaceId == destination }?.key)
        XCTAssertEqual(projection.layoutsByMonitor[firstMonitor.id]?.anchorWorkspaceId, fixture.workspaceId)
        XCTAssertEqual(projection.layoutsByMonitor[otherMonitor.id]?.anchorWorkspaceId, otherWorkspace)

        fixture.controller.windowActionHandler.prepareOverviewSelection(handle: target, workspaceId: destination)
        projection.settleRestFrames(targetWindow: target)

        XCTAssertEqual(projection.layoutsByMonitor[firstMonitor.id]?.anchorWorkspaceId, destination)
        XCTAssertEqual(projection.layoutsByMonitor[otherMonitor.id]?.anchorWorkspaceId, otherWorkspace)
        XCTAssertEqual(manager.activeWorkspace(on: firstMonitor.id)?.id, destination)
        XCTAssertEqual(manager.activeWorkspace(on: otherMonitor.id)?.id, otherWorkspace)
        projection.settleRestFrames(targetWindow: nil)
        XCTAssertEqual(projection.layoutsByMonitor[firstMonitor.id]?.anchorWorkspaceId, destination)
        XCTAssertEqual(projection.layoutsByMonitor[otherMonitor.id]?.anchorWorkspaceId, otherWorkspace)
        while let task = fixture.controller.layoutRefreshController.layoutState.activeRefreshTask { await task.value }
    }

    func testEachMonitorPanelListsOnlyItsOwnWorkspacesAndDragsRemapAcrossPanels() async throws {
        let fixture = try makeRuntimeOverviewFixture(windowCount: 1, secondWorkspaceWindowCount: 1)
        let manager = fixture.controller.workspaceManager
        let firstMonitor = try XCTUnwrap(manager.monitors.first)
        let otherMonitor = Monitor(
            id: .init(displayId: 91_003),
            displayId: 91_003,
            frame: screenFrame.offsetBy(dx: 1000, dy: 200),
            visibleFrame: screenFrame.offsetBy(dx: 1000, dy: 200),
            hasNotch: false,
            name: "Other Overview"
        )
        fixture.controller.settings.workspaces.configurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .main, layoutType: .niri),
            WorkspaceConfiguration(name: "2", monitorAssignment: .main, layoutType: .niri),
            WorkspaceConfiguration(
                name: "3",
                monitorAssignment: .specificDisplay(OutputId(from: otherMonitor)),
                layoutType: .niri
            )
        ]
        manager.applyMonitorConfigurationChange([firstMonitor, otherMonitor])
        manager.applySettings()
        fixture.controller.syncMonitorsToNiriEngine()
        let destination = try XCTUnwrap(fixture.secondWorkspaceId)
        manager.assignWorkspaceToMonitor(fixture.workspaceId, monitorId: firstMonitor.id)
        manager.assignWorkspaceToMonitor(destination, monitorId: firstMonitor.id)
        let otherWorkspace = try XCTUnwrap(manager.workspaceId(for: "3", createIfMissing: true))
        manager.assignWorkspaceToMonitor(otherWorkspace, monitorId: otherMonitor.id)
        XCTAssertTrue(manager.setActiveWorkspace(fixture.workspaceId, on: firstMonitor.id))
        XCTAssertTrue(manager.setActiveWorkspace(otherWorkspace, on: otherMonitor.id))
        let snapshot = OverviewSnapshot(
            wmController: fixture.controller,
            facts: OverviewWindowFacts(wmController: fixture.controller, environment: fixture.environment)
        )
        snapshot.build()
        let projection = OverviewViewportProjection(wmController: fixture.controller, snapshot: snapshot, scale: 1)
        projection.rebuildProjectedLayouts()

        let firstLayout = try XCTUnwrap(projection.layoutsByMonitor[firstMonitor.id])
        let otherLayout = try XCTUnwrap(projection.layoutsByMonitor[otherMonitor.id])
        XCTAssertEqual(
            Set(firstLayout.workspaceSections.map(\.workspaceId)),
            Set(manager.workspaces(on: firstMonitor.id).map(\.id))
        )
        XCTAssertEqual(otherLayout.workspaceSections.map(\.workspaceId), [otherWorkspace])
        XCTAssertTrue(otherLayout.allWindows.isEmpty)
        XCTAssertEqual(Set(firstLayout.allWindows.map(\.handle)), Set(snapshot.windows.keys))

        let insideFirst = CGPoint(x: 400, y: 300)
        let insideFirstLocation = projection.pointerLocation(from: insideFirst, on: firstMonitor.id)
        XCTAssertEqual(insideFirstLocation.monitorId, firstMonitor.id)
        XCTAssertEqual(insideFirstLocation.point, insideFirst)
        let beyondFirst = CGPoint(x: 1300, y: 500)
        let remapped = projection.pointerLocation(from: beyondFirst, on: firstMonitor.id)
        XCTAssertEqual(remapped.monitorId, otherMonitor.id)
        XCTAssertEqual(remapped.point, CGPoint(x: 300, y: 300))
        let outsideEveryMonitor = CGPoint(x: 5000, y: 5000)
        XCTAssertEqual(
            projection.pointerLocation(from: outsideEveryMonitor, on: firstMonitor.id).monitorId,
            firstMonitor.id
        )
        while let task = fixture.controller.layoutRefreshController.layoutState.activeRefreshTask { await task.value }
    }

    func testAnimatorExcludesUnavailableDisplaysWhileInstalledAnimationsCompleteNormally() throws {
        let fixture = try makeRuntimeOverviewFixture(windowCount: 1)
        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy,
            environment: fixture.environment
        )
        let availableDisplayId: CGDirectDisplayID = 91_001
        let missingDisplayId: CGDirectDisplayID = 91_002
        let animator = OverviewAnimator(
            controller: overview,
            animationInstaller: { displayId, _, _ in
                displayId == availableDisplayId
            },
            mediaTimeProvider: { 0 }
        )

        animator.startOpenAnimation(displayIds: [availableDisplayId, missingDisplayId])
        XCTAssertEqual(animator.activeDisplayIds, [availableDisplayId])
        XCTAssertEqual(animator.completionCount, 0)

        let generation = animator.generation

        completeAnimator(animator, displayId: availableDisplayId, generation: generation)

        XCTAssertTrue(animator.activeDisplayIds.isEmpty)
        XCTAssertEqual(animator.completionCount, 1)
        guard case .open = overview.state else {
            return XCTFail("Expected the available display session to release the barrier")
        }
    }

    func testAnimatorCompletesWhenEveryDisplayIsUnavailable() throws {
        let fixture = try makeRuntimeOverviewFixture(windowCount: 1)
        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy,
            environment: fixture.environment
        )
        let animator = OverviewAnimator(
            controller: overview,
            animationInstaller: { _, _, _ in false },
            mediaTimeProvider: { 0 }
        )

        animator.startOpenAnimation(displayIds: [91_001, 91_002])

        XCTAssertTrue(animator.activeDisplayIds.isEmpty)
        XCTAssertEqual(animator.completionCount, 1)
        guard case .open = overview.state else {
            return XCTFail("Expected unavailable displays to snap open")
        }
    }

    func testScreenParametersNotificationClosesOpeningOverviewSynchronously() throws {
        try assertScreenParametersNotificationClosesOverview(during: .opening)
    }

    func testScreenParametersNotificationClosesOpenOverviewSynchronously() throws {
        try assertScreenParametersNotificationClosesOverview(during: .open)
    }

    func testScreenParametersNotificationClosesClosingOverviewSynchronously() throws {
        try assertScreenParametersNotificationClosesOverview(during: .closing)
    }

    func testCloseSelectionWaitsForAuthoritativeRemovalBeforeAdvancing() throws {
        let fixture = try makeRuntimeOverviewFixture(windowCount: 2)
        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy,
            environment: fixture.environment
        )
        overview.prepareOpenState()
        overview.onAnimationComplete(state: .open)
        let removedHandle = try XCTUnwrap(overview.selectedWindowHandle)
        let expectedSuccessorToken = try XCTUnwrap(
            fixture.handles.first { $0.id != removedHandle.id }
        ).id
        var closeAccepted = false
        overview.onCloseWindow = { handle in
            XCTAssertEqual(handle, removedHandle)
            return closeAccepted
        }
        fixture.controller.workspaceManager.onWindowRemoved = { entry in
            XCTAssertNil(fixture.controller.workspaceManager.entry(for: entry.token))
            overview.handleManagedWindowRemoved(entry)
        }

        overview.input.closeSelectedWindow()
        XCTAssertEqual(overview.selectedWindowHandle, removedHandle)

        closeAccepted = true
        overview.input.closeSelectedWindow()
        XCTAssertEqual(overview.selectedWindowHandle, removedHandle)

        _ = fixture.controller.workspaceManager.removeWindow(
            pid: removedHandle.id.pid,
            windowId: removedHandle.id.windowId
        )

        XCTAssertEqual(overview.selectedWindowHandle?.id, expectedSuccessorToken)
    }

    func testOverviewSnapshotExcludesHiddenApplicationWindows() throws {
        var titleReads = 0
        var frameReads = 0
        var fixture = try makeRuntimeOverviewFixture(windowCount: 2)
        fixture.environment.windowTitle = { _ in
            titleReads += 1
            return "Window"
        }
        fixture.environment.windowFrame = { _ in
            frameReads += 1
            return CGRect(x: 10, y: 10, width: 500, height: 400)
        }
        let hiddenToken = fixture.handles[0].id
        let visibleToken = fixture.handles[1].id
        fixture.controller.workspaceManager.setAppHidden(
            true,
            pid: hiddenToken.pid,
            source: .service
        )
        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy,
            environment: fixture.environment
        )

        overview.prepareOpenState()

        XCTAssertEqual(overview.selectedWindowHandle?.id, visibleToken)
        XCTAssertEqual(titleReads, 1)
        XCTAssertEqual(frameReads, 1)
    }

    func testCachedProjectionRemovesAndRestoresHiddenNiriWindow() throws {
        var titleReads = 0
        var fixture = try makeRuntimeOverviewFixture(windowCount: 2)
        fixture.environment.windowTitle = { _ in
            titleReads += 1
            return "Window"
        }
        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy,
            environment: fixture.environment
        )
        overview.prepareOpenState()
        overview.onAnimationComplete(state: .open)
        let hiddenHandle = try XCTUnwrap(overview.selectedWindowHandle)

        titleReads = 0
        fixture.controller.workspaceManager.setAppHidden(
            true,
            pid: hiddenHandle.pid,
            source: .service
        )
        overview.refreshCachedOverviewProjection(affectedWorkspaceIds: [fixture.workspaceId])

        XCTAssertNotEqual(overview.selectedWindowHandle, hiddenHandle)
        XCTAssertEqual(titleReads, 0)

        fixture.controller.workspaceManager.setAppHidden(
            false,
            pid: hiddenHandle.pid,
            source: .service
        )
        overview.refreshCachedOverviewProjection(
            affectedWorkspaceIds: [fixture.workspaceId],
            selectedHandle: hiddenHandle
        )

        XCTAssertEqual(overview.selectedWindowHandle, hiddenHandle)
        XCTAssertEqual(titleReads, 1)
    }

    func testCachedProjectionRefreshDoesNotRereadWindowMetadataOrRestartCapture() throws {
        var titleReads = 0
        var frameReads = 0
        var captureStarts = 0
        var fixture = try makeRuntimeOverviewFixture(windowCount: 2)
        fixture.environment.windowTitle = { _ in
            titleReads += 1
            return "Window"
        }
        fixture.environment.windowFrame = { _ in
            frameReads += 1
            return CGRect(x: 10, y: 10, width: 500, height: 400)
        }
        fixture.environment.onThumbnailCaptureStarted = {
            captureStarts += 1
        }
        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy,
            environment: fixture.environment
        )
        overview.prepareOpenState()
        overview.onAnimationComplete(state: .open)
        XCTAssertEqual(titleReads, 2)
        XCTAssertEqual(frameReads, 2)

        titleReads = 0
        frameReads = 0
        overview.refreshCachedOverviewProjection(affectedWorkspaceIds: [fixture.workspaceId])
        overview.refreshCachedOverviewProjection(affectedWorkspaceIds: [fixture.workspaceId])

        XCTAssertEqual(titleReads, 0)
        XCTAssertEqual(frameReads, 0)
        XCTAssertEqual(captureStarts, 0)
    }

    func testDismissedOverviewRejectsLatePreviewFrame() async throws {
        let fixture = try makeRuntimeOverviewFixture(windowCount: 1)
        let driver = OverviewPreviewTestDriver()
        let capture = driver.makeCapture()
        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy,
            environment: fixture.environment,
            previewCapture: capture
        )
        overview.prepareOpenState()
        overview.onAnimationComplete(state: .open)
        let handle = try XCTUnwrap(overview.selectedWindowHandle)
        capture.reconcile(represented: [handle], visible: [
            OverviewPreviewRequest(handle: handle, pixelWidth: 80, pixelHeight: 60)
        ])
        await driver.waitForStarts(1)
        let frame = try makeOverviewPreviewFrame()
        let published = expectation(description: "preview published independently")
        capture.onPreview = { _, frame in if frame != nil { published.fulfill() } }
        driver.streams[0].output.offer(frame)
        await fulfillment(of: [published], timeout: 1)
        XCTAssertTrue(capture.preview(for: handle) === frame)

        overview.dismiss(animated: false)
        XCTAssertTrue(capture.preview(for: handle) === frame)
        driver.streams[0].output.offer(frame)
        XCTAssertNil(driver.streams[0].output.take())
        driver.completeAllStarts()
        XCTAssertTrue(capture.preview(for: handle) === frame)
    }

    func testReopenedOverviewRejectsPreviousSessionFrames() async throws {
        let fixture = try makeRuntimeOverviewFixture(windowCount: 1)
        let driver = OverviewPreviewTestDriver()
        let capture = driver.makeCapture()
        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy,
            environment: fixture.environment,
            previewCapture: capture
        )
        let handle = try XCTUnwrap(fixture.handles.first)
        let request = OverviewPreviewRequest(handle: handle, pixelWidth: 80, pixelHeight: 60)
        overview.prepareOpenState()
        overview.onAnimationComplete(state: .open)
        capture.reconcile(represented: [handle], visible: [request])
        await driver.waitForStarts(1)
        overview.dismiss(animated: false)
        driver.completeAllStarts()

        overview.prepareOpenState()
        overview.onAnimationComplete(state: .open)
        capture.reconcile(represented: [handle], visible: [request])
        await driver.waitForStarts(2)
        let oldFrame = try makeOverviewPreviewFrame()
        let newFrame = try makeOverviewPreviewFrame()
        let published = expectation(description: "new session preview")
        capture.onPreview = { _, frame in if frame != nil { published.fulfill() } }
        driver.streams[1].output.offer(newFrame)
        driver.streams[0].output.offer(oldFrame)
        await fulfillment(of: [published], timeout: 1)
        XCTAssertTrue(capture.preview(for: handle) === newFrame)
        XCTAssertNil(driver.streams[0].output.take())
        driver.completeAllStarts()
        overview.dismiss(animated: false)
    }

    private func makeGeometryLayout(scale: CGFloat = 1) -> OverviewLayout {
        var layout = OverviewLayout()
        layout.scale = scale
        layout.searchBarFrame = CGRect(x: 250, y: 720, width: 500, height: 44)
        layout.totalContentHeight = 2000
        return layout
    }

    private struct ProjectionFixture {
        var workspaces: [OverviewWorkspaceLayoutItem]
        var windows: [WindowHandle: OverviewWindowLayoutData]
        var rowHandles: [[WindowHandle]] = []
    }

    private struct RuntimeOverviewFixture {
        let controller: WMController
        let workspaceId: WorkspaceDescriptor.ID
        let handles: [WindowHandle]
        let secondWorkspaceId: WorkspaceDescriptor.ID?
        var environment: OverviewEnvironment
    }

    private enum ScreenParametersOverviewPhase: Equatable {
        case opening
        case open
        case closing
    }

    private func assertScreenParametersNotificationClosesOverview(
        during phase: ScreenParametersOverviewPhase
    ) throws {
        let fixture = try makeRuntimeOverviewFixture(windowCount: 1)
        fixture.controller.motionPolicy.animationsEnabled = true
        let notificationCenter = NotificationCenter()
        var animationCompletions: [OverviewAnimationCompletion] = []
        var removedEventMonitorCount = 0
        var environment = fixture.environment
        environment.frontmostApplicationPID = { nil }
        environment.activateOmniWM = {}
        environment.notificationCenter = notificationCenter
        environment.addLocalEventMonitor = { _, _ in NSObject() }
        environment.removeEventMonitor = { _ in removedEventMonitorCount += 1 }
        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy,
            environment: environment,
            animationInstaller: { _, _, completion in
                animationCompletions.append(completion)
                return true
            },
            animationMediaTimeProvider: { 0 }
        )

        overview.open()
        let animator = try XCTUnwrap(animationCompletions.last?.animator)
        let openingGeneration = animator.generation

        switch phase {
        case .opening:
            guard case .opening = overview.state else {
                return XCTFail("Expected Overview to be opening")
            }
        case .open:
            completeAnimator(animator, displayId: 91_001, generation: openingGeneration)
            guard case .open = overview.state else {
                return XCTFail("Expected Overview to be open")
            }
        case .closing:
            completeAnimator(animator, displayId: 91_001, generation: openingGeneration)
            overview.dismiss(reason: .cancel, animated: true)
            guard case .closing = overview.state else {
                return XCTFail("Expected Overview to be closing")
            }
        }

        if phase == .open {
            XCTAssertFalse(animator.isAnimating)
            XCTAssertTrue(animator.activeDisplayIds.isEmpty)
        } else {
            XCTAssertTrue(animator.isAnimating)
            XCTAssertEqual(animator.activeDisplayIds, [91_001])
        }

        notificationCenter.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)

        guard case .closed = overview.state else {
            return XCTFail("Expected the topology notification to synchronously close Overview")
        }
        XCTAssertFalse(animator.isAnimating)
        XCTAssertTrue(animator.activeDisplayIds.isEmpty)
        XCTAssertEqual(removedEventMonitorCount, 1)
        XCTAssertNil(overview.selectedWindowHandle)
        XCTAssertNil(overview.activeInteractionMonitorId)
        XCTAssertFalse(overview.hasActiveDragSession)
    }

    private func makeRuntimeOverviewFixture(
        windowCount: Int,
        secondWorkspaceWindowCount: Int = 0
    ) throws -> RuntimeOverviewFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMOverviewBehaviorTests-\(UUID().uuidString)", isDirectory: true)
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config", isDirectory: true),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: false
        )
        let controller = WMController(
            settings: settings,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, _, _ in },
                raiseWindow: { _ in }
            )
        )
        controller.motionPolicy.animationsEnabled = false
        let monitor = Monitor(
            id: .init(displayId: 91_001),
            displayId: 91_001,
            frame: screenFrame,
            visibleFrame: screenFrame,
            hasNotch: false,
            name: "Overview"
        )
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        controller.workspaceManager.assignWorkspaceToMonitor(workspaceId, monitorId: monitor.id)
        XCTAssertTrue(controller.workspaceManager.setActiveWorkspace(workspaceId, on: monitor.id))

        let secondWorkspaceId = secondWorkspaceWindowCount > 0
            ? controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
            : nil
        if let secondWorkspaceId {
            controller.workspaceManager.assignWorkspaceToMonitor(secondWorkspaceId, monitorId: monitor.id)
            controller.niriEngine = NiriLayoutEngine()
            controller.niriLayoutHandler.syncMonitorsToNiriEngine()
        }
        let handles = (0 ..< windowCount + secondWorkspaceWindowCount).map { index in
            let pid = pid_t(91_100 + index)
            let windowId = 91_200 + index
            let destination = index < windowCount ? workspaceId : (secondWorkspaceId ?? workspaceId)
            let token = controller.workspaceManager.addWindow(
                AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
                pid: pid,
                windowId: windowId,
                to: destination
            )
            if secondWorkspaceId != nil {
                controller.workspaceManager.withEngineMutationScope {
                    _ = controller.niriEngine?.addWindow(
                        token: token,
                        to: destination,
                        afterSelection: nil
                    )
                }
            }
            return WindowHandle(id: token)
        }
        var environment = OverviewEnvironment()
        environment.windowTitle = { _ in "Window" }
        environment.windowFrame = { _ in CGRect(x: 10, y: 10, width: 500, height: 400) }
        return RuntimeOverviewFixture(
            controller: controller,
            workspaceId: workspaceId,
            handles: handles,
            secondWorkspaceId: secondWorkspaceId,
            environment: environment
        )
    }

    private func completeAnimator(
        _ animator: OverviewAnimator,
        displayId: CGDirectDisplayID,
        generation: UInt64
    ) {
        animator.animationCompleted(displayId: displayId, generation: generation)
    }

    private func makeProjectionFixture() -> ProjectionFixture {
        makeProjectionFixture(windowCountsPerWorkspace: [1, 1, 1])
    }

    private func makeProjectionFixture(windowCountsPerWorkspace: [Int]) -> ProjectionFixture {
        let descriptors = ["First", "Second", "Third"].map { WorkspaceDescriptor(name: $0) }
        precondition(windowCountsPerWorkspace.count == descriptors.count)
        let workspaces = descriptors.enumerated().map { index, descriptor in
            OverviewWorkspaceLayoutItem(id: descriptor.id, name: descriptor.name, isActive: index == 0)
        }
        var windows: [WindowHandle: OverviewWindowLayoutData] = [:]
        var rowHandles: [[WindowHandle]] = []
        var tokenSeed = 0
        for (index, descriptor) in descriptors.enumerated() {
            let windowCount = windowCountsPerWorkspace[index]
            let columnWidth = 1000.0 / CGFloat(windowCount)
            var row: [WindowHandle] = []
            for slot in 0 ..< windowCount {
                tokenSeed += 1
                let token = WindowToken(pid: pid_t(tokenSeed), windowId: tokenSeed)
                let handle = WindowHandle(id: token)
                windows[handle] = OverviewWindowLayoutData(
                    token: token,
                    workspaceId: descriptor.id,
                    title: "\(descriptor.name) \(slot + 1)",
                    appName: "App \(tokenSeed)",
                    appIcon: nil,
                    frame: CGRect(x: columnWidth * CGFloat(slot), y: 0, width: columnWidth, height: 700)
                )
                row.append(handle)
            }
            rowHandles.append(row)
        }
        return ProjectionFixture(workspaces: workspaces, windows: windows, rowHandles: rowHandles)
    }

    private func projectedLayout(
        fixture: ProjectionFixture,
        scale: CGFloat,
        query: String
    ) -> OverviewLayout {
        OverviewLayoutCalculator(
            screenFrame: screenFrame,
            scale: scale
        ).calculateLayout(
            workspaces: fixture.workspaces,
            windows: fixture.windows,
            searchQuery: query
        )
    }

    private func revealSelection(_ selectedHandle: WindowHandle, in layout: inout OverviewLayout) {
        guard let selected = layout.window(for: selectedHandle) else { return }
        layout.scrollOffset = OverviewLayoutCalculator.scrollOffsetRevealing(
            targetFrame: selected.overviewFrame,
            currentOffset: layout.scrollOffset,
            layout: layout,
            screenFrame: screenFrame
        )
    }

    private func assertViewportInvariant(
        _ layout: OverviewLayout,
        selectedHandle: WindowHandle?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let bounds = OverviewLayoutCalculator.scrollOffsetBounds(layout: layout, screenFrame: screenFrame)
        XCTAssertTrue(bounds.contains(layout.scrollOffset), file: file, line: line)
        if let selectedHandle,
           let selected = layout.window(for: selectedHandle),
           selected.matchesSearch
        {
            assertVisible(selected.overviewFrame, in: layout, offset: layout.scrollOffset, file: file, line: line)
        }
    }

    private func assertVisible(
        _ target: CGRect,
        in layout: OverviewLayout,
        offset: CGFloat,
        message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let viewport = OverviewLayoutCalculator.visibleContentFrame(
            layout: layout,
            screenFrame: screenFrame,
            scrollOffset: offset
        )
        guard target.height <= viewport.height else { return }
        let padding = min(
            OverviewLayoutMetrics.windowSpacing * OverviewLayoutCalculator.clampedScale(layout.scale),
            max(0, (viewport.height - target.height) / 2)
        )
        let paddedViewport = viewport.insetBy(dx: 0, dy: padding)
        XCTAssertGreaterThanOrEqual(target.minY + 0.0001, paddedViewport.minY, message, file: file, line: line)
        XCTAssertLessThanOrEqual(target.maxY - 0.0001, paddedViewport.maxY, message, file: file, line: line)
    }
}
