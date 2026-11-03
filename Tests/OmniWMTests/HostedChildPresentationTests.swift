// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMIPC
import XCTest

@MainActor
final class HostedChildPresentationTests: XCTestCase {
    func testSwitcherListsUtilitiesAndRepresentsSheetFocusThroughItsParent() throws {
        let fixture = try HostedChildPresentationFixture()
        defer { fixture.close() }
        let sheet = try XCTUnwrap(fixture.sheet)
        let controller = fixture.base.controller
        let manager = fixture.base.world
        controller.settings.windowSwitcher.enabled = true
        controller.settings.windowSwitcher.order = .lastUsed
        for token in [fixture.parent.token, fixture.utility.token, fixture.external.token, sheet.token] {
            XCTAssertTrue(manager.setManagedFocus(token, in: fixture.base.workspace))
        }
        controller.commandHandler.frontmostAppPidProvider = { sheet.pid }
        controller.commandHandler.frontmostFocusedWindowTokenProvider = { sheet.token }
        let driver = OverviewPreviewTestDriver()
        let capture = driver.makeCapture(consumer: .windowSwitcher, hasCaptureAccess: { false })
        let switcher = WindowSwitcherController(controller: controller, previewCapture: capture)
        defer { switcher.shutdown()
            driver.finish()
        }

        switcher.handle(.begin(reverse: false, scope: .activeWorkspace))

        let panel = try XCTUnwrap(controller.ownedWindowRegistry.visibleWindows().first as? WindowSwitcherPanel)
        let content = try XCTUnwrap(panel.contentView)
        let cards = presentationSubviews(WindowSwitcherTile.self, in: content)
        XCTAssertEqual(cards.map(\.handle.id), [fixture.parent.token, fixture.external.token, fixture.utility.token])
        XCTAssertEqual(
            cards.filter { $0.layer?.borderWidth == WindowSwitcherTile.selectedBorderWidth }.map(\.handle.id),
            [fixture.external.token]
        )
        let utility = try XCTUnwrap(cards.first { $0.handle.id == fixture.utility.token })
        XCTAssertEqual(utility.toolTip, fixture.utilityTitle)
        XCTAssertTrue(utility.handle === manager.handle(for: fixture.utility.token))
        try assertHostedSymbol(
            presentationSubviews(NSImageView.self, in: utility).first?.image,
            named: fixture.icon
        )
        let parent = try XCTUnwrap(cards.first { $0.handle.id == fixture.parent.token })
        XCTAssertEqual(parent.toolTip, fixture.parentTitle + " — " + String(localized: "Dialog open"))
        fixture.base.management.manager.windows[sheet.token]?.close()
        XCTAssertNil(manager.entry(for: sheet.token))

        switcher.refreshWindows()

        XCTAssertEqual(
            presentationSubviews(WindowSwitcherTile.self, in: content)
                .first { $0.handle.id == fixture.parent.token }?.toolTip,
            fixture.parentTitle
        )
    }

    func testOverviewExcludesSheetsAndRetainsUtilityTitlesWithoutStructuralActions() async throws {
        for layout in [LayoutType.niri, .dwindle] {
            let fixture = try HostedChildPresentationFixture(layout: layout)
            defer { fixture.close() }
            let sheet = try XCTUnwrap(fixture.sheet)
            let controller = fixture.base.controller
            let manager = fixture.base.world
            controller.layoutRefreshController.requestRelayout(
                reason: .axWindowChanged, affectedWorkspaceIds: [fixture.base.workspace]
            )
            await WindowAdmissionTestSupport.drainLayoutRefreshes(controller)
            var environment = OverviewEnvironment()
            environment.windowFrame = { _ in fixture.base.management.externalFrame }
            environment.windowTitle = { _ in fixture.base.externalTitle }
            let facts = OverviewWindowFacts(wmController: controller, environment: environment)
            XCTAssertFalse(facts.isOverviewEligible(sheet, workspaceManager: manager))
            XCTAssertTrue(facts.isOverviewEligible(fixture.utility, workspaceManager: manager))
            XCTAssertFalse(facts.isStructurallyMutable(fixture.utility))
            XCTAssertTrue(facts.isStructurallyMutable(fixture.parent))
            XCTAssertTrue(facts.isStructurallyMutable(fixture.external))
            let snapshot = OverviewSnapshot(wmController: controller, facts: facts)
            snapshot.build()
            XCTAssertEqual(
                Set(snapshot.windows.keys.map(\.id)),
                Set([fixture.parent.token, fixture.utility.token, fixture.external.token])
            )
            let utilityHandle = try XCTUnwrap(manager.handle(for: fixture.utility.token))
            let parentHandle = try XCTUnwrap(manager.handle(for: fixture.parent.token))
            let utility = try XCTUnwrap(snapshot.windows[utilityHandle])
            XCTAssertEqual(utility.title, fixture.utilityTitle)
            XCTAssertEqual(utility.frame, fixture.base.management.manager.windows[fixture.utility.token]?.frame)
            XCTAssertEqual(
                snapshot.windows[parentHandle]?.title,
                fixture.parentTitle + " — " + String(localized: "Dialog open")
            )
            try fixture.confirmFocus(sheet)
            XCTAssertEqual(manager.selectedManagedToken, sheet.token)
            XCTAssertEqual(controller.monitorForInteraction()?.id, fixture.base.management.sourceMonitor.id)
            let driver = OverviewPreviewTestDriver()
            let overview = OverviewController(
                wmController: controller, motionPolicy: controller.motionPolicy, environment: environment,
                previewCapture: driver.makeCapture(hasCaptureAccess: { false })
            )
            defer { overview.invalidateDeferredActionsForServiceStop()
                driver.finish()
            }
            overview.prepareOpenState()
            overview.onAnimationComplete(state: .open)
            XCTAssertTrue(overview.selectedWindowHandle === parentHandle)
            overview.drag.beginDrag(
                on: fixture.base.management.sourceMonitor.id,
                handle: utilityHandle,
                startPoint: .zero
            )
            XCTAssertFalse(overview.hasActiveDragSession)
            XCTAssertEqual(
                overview.performStructuralHotkey(.workspace(.moveTo(1)), selectedHandle: utilityHandle),
                .unchanged
            )
            XCTAssertEqual(manager.workspace(for: fixture.utility.token), fixture.base.workspace)
            fixture.base.management.manager.windows[sheet.token]?.close()
            snapshot.refresh(affectedWorkspaceIds: [fixture.base.workspace], settledNiriFrames: true)
            XCTAssertEqual(snapshot.windows[parentHandle]?.title, fixture.parentTitle)
        }
    }

    func testOnlySheetsSuppressCompleteAndAnimationBorders() throws {
        let fixture = try HostedChildPresentationFixture()
        defer { fixture.close() }
        let sheet = try XCTUnwrap(fixture.sheet)
        let controller = fixture.base.controller
        let manager = fixture.base.world
        controller.settings.borders.enabled = true
        let frame = fixture.base.management.centeredFrame(on: fixture.base.management.sourceMonitor)
        let config = BorderConfig.from(settings: controller.settings, isDark: controller.borderUsesDarkAppearance)
        var liveQueries: [Int] = []
        let world = WorldView(controller: controller, liveBoundsProvider: { id in
            liveQueries.append(id)
            return frame
        })
        for entry in [fixture.parent, fixture.utility, fixture.external] {
            XCTAssertTrue(manager.setManagedFocus(entry.token, in: fixture.base.workspace))
            let previous = DesiredBorderSurface(token: entry.token, frame: frame, config: config)
            XCTAssertEqual(SurfaceDerivation.deriveBorder(world: world)?.token, entry.token)
            XCTAssertEqual(SurfaceDerivation.deriveBorder(world: world)?.frame, frame)
            let animation = try XCTUnwrap(SurfaceDerivation.deriveAnimationBorder(world: world, previous: previous))
            XCTAssertEqual(animation.token, entry.token)
            XCTAssertEqual(animation.config, config)
            XCTAssertEqual(
                animation.frame,
                entry.mode == .floating
                    ? fixture.base.management.manager.windows[entry.token]?.frame ?? frame : frame
            )
        }
        liveQueries.removeAll()
        XCTAssertTrue(manager.setManagedFocus(sheet.token, in: fixture.base.workspace))
        let previous = DesiredBorderSurface(token: sheet.token, frame: frame, config: config)

        XCTAssertNil(SurfaceDerivation.deriveBorder(world: world))
        XCTAssertNil(SurfaceDerivation.deriveAnimationBorder(world: world, previous: previous))
        XCTAssertTrue(liveQueries.isEmpty)
    }
}

@MainActor
final class HostedChildPresentationFixture {
    let base: HostedPresentationFixture
    let parent: WindowState
    let utility: WindowState
    let sheet: WindowState?
    let external: WindowState
    let parentTitle = "Family document"
    let utilityTitle = "Family inspector"
    let icon = "slider.horizontal.3"

    init(layout: LayoutType = .dwindle, includesSheet: Bool = true) throws {
        base = try HostedPresentationFixture(layout: layout)
        let metadata = HostedWindowMetadata(
            appId: "child-presentation", title: parentTitle,
            minimumSize: base.management.definition.minimumContentSize, icon: icon
        )
        parent = try base.add(metadata)
        utility = try base.add(HostedWindowMetadata(
            appId: metadata.appId, title: utilityTitle, minimumSize: metadata.minimumSize, icon: metadata.icon,
            instanceID: metadata.instanceID, role: .utility(parent: parent.token, declarationID: "inspector")
        ))
        if includesSheet {
            sheet = try base.add(HostedWindowMetadata(
                appId: metadata.appId, title: "Family confirmation", minimumSize: metadata.minimumSize,
                icon: metadata.icon, instanceID: metadata.instanceID,
                role: .sheet(parent: parent.token, declarationID: "confirm")
            ))
        } else {
            sheet = nil
        }
        external = try base.addExternal()
    }

    func close() {
        base.close()
    }

    func confirmFocus(_ entry: WindowState) throws {
        let request = try XCTUnwrap(base.controller.focusWindow(entry.token))
        XCTAssertEqual(request.token, entry.token)
        let window = try XCTUnwrap(base.management.manager.windows[entry.token])
        base.management.manager.windowDidBecomeKey(
            base.management.notification(window, name: NSWindow.didBecomeKeyNotification)
        )
        XCTAssertEqual(base.world.nativeManagedFocusToken, entry.token)
        XCTAssertEqual(base.world.selectedManagedToken, entry.token)
        XCTAssertNil(base.world.pendingFocusedToken)
    }
}
