// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class ShellFocusTransferTests: XCTestCase {
    @MainActor
    private final class Fixture {
        let widget: ShellRenderedWidget
        let panel: ShellFocusPanel

        init(_ panel: ShellFocusPanel? = nil, input: Bool = false) throws {
            _ = NSApplication.shared
            widget = try ShellRenderedWidget(name: "focus-transfer", source: input ? """
            function render(ctx)
                return ui.input{key='editor',w=120,h=60,multiline=true,text='native',onCancel=function() end}
            end
            """ : """
            function render(ctx)
                return ui.box{w=120,h=60,focusable=true,keys={'escape'},onKey=function() end}
            end
            """)
            widget.render(ShellBarData())
            self.panel = panel ?? ShellPopoutPanel(content: widget.surface.view)
            if panel != nil { self.panel.contentView = widget.surface.view }
            self.panel.setFrame(CGRect(x: 20, y: 20, width: 120, height: 60), display: false)
            widget.surface.view.frame = CGRect(x: 0, y: 0, width: 120, height: 60)
            self.panel.orderFrontRegardless()
            widget.surface.setVisible(true)
            OwnedWindowRegistry.shared.register(
                self.panel, surfaceId: "focus-test-\(ObjectIdentifier(self.panel))",
                policy: SurfacePolicy(
                    kind: .workspaceBar,
                    hitTestPolicy: .interactive,
                    capturePolicy: .excluded,
                    suppressesManagedFocusRecovery: false
                )
            )
        }

        func connect(_ host: ShellWidgetHost) {
            host.connectSurfaceFocus(widget.surface) { true }
        }

        func focus() {
            widget.surface.focusDeclared(widget.surface.layout.core.rootHandle)
        }

        func close() {
            widget.surface.blurDeclaredFocus()
            OwnedWindowRegistry.shared.unregister(panel)
            panel.close()
        }
    }

    private func host(_ policy: FocusPolicyEngine) -> ShellWidgetHost {
        ShellWidgetHost(
            configDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            resources: ShellResources(motion: MotionPolicy(animationsEnabled: false)), focusPolicyEngine: policy,
            world: { ShellWorldData() }, vars: { [:] }, bars: { [:] }, onLayoutChange: {},
            onCommand: { _, _ in }, onMenu: { _ in }, onPreview: { _ in }, onDrag: { _ in },
            onPopoutChange: {}, onTitleDemandChange: { _ in }
        )
    }

    func testIslandPopoutBarAndDrawerTransferKeepsOneLeaseAndOriginalReturnTarget() throws {
        let policy = FocusPolicyEngine()
        let host = host(policy)
        let widget = try ShellRenderedWidget(
            name: "focus-island",
            source: "function render(ctx) return ui.box{w=120,h=60,focusable=true} end"
        )
        widget.render(ShellBarData())
        let monitor = Monitor(
            id: .init(displayId: 95401), displayId: 95401,
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 868), hasNotch: false, name: "Focus fixture"
        )
        let island = ShellIsland(surface: widget.surface, monitor: monitor, size: CGSize(width: 200, height: 100))
        host.islandWindows[monitor.id] = island
        host.connectIslandInput(island, on: monitor.id)
        island.update(monitor: monitor, size: CGSize(width: 200, height: 100), visible: true, level: .normal)
        let popout = try Fixture()
        let bar = try Fixture(WorkspaceBarPanel.defaultPanel())
        let drawerWidget = try ShellRenderedWidget(
            name: "focus-drawer",
            source: "function render(ctx) return ui.text{text='Draw',onClick=function() end} end"
        )
        drawerWidget.render(ShellBarData())
        drawerWidget.surface.focusAxis = .vertical
        let chrome = ShellDrawerChrome(
            content: drawerWidget.surface.view,
            placement: HiddenBarPanelPlacement(
                attachment: PopupAttachment(anchor: CGPoint(x: 300, y: 700)),
                visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900)
            ), motion: MotionPolicy(animationsEnabled: false), onJoin: { _ in }
        )
        chrome.onKeyboardFocus = { active in
            if active { host.focusShellSurface(drawerWidget.surface, keyboardNavigation: true) }
            else { host.releaseShellFocus(from: drawerWidget.surface, restore: true) }
        }
        popout.connect(host)
        bar.connect(host)
        defer { chrome.close(animated: false)
            popout.close()
            bar.close()
            host.closeIslands()
        }
        var leaseChanges = 0
        policy.onLeaseChanged = { _ in leaseChanges += 1 }
        widget.surface.focusDeclared(widget.surface.layout.core.rootHandle)
        XCTAssertEqual(host.focusedIsland, monitor.id)
        let returnWindow = ShellFocusPanel(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        let returnResponder = NSView()
        host.shellPreviousKeyWindow = returnWindow
        host.shellPreviousFirstResponder = returnResponder
        popout.focus()
        XCTAssertTrue(host.focusedSurface === popout.widget.surface)
        XCTAssertNil(host.focusedIsland)
        XCTAssertFalse(island.panel.canBecomeKey)
        bar.focus()
        XCTAssertTrue(host.focusedSurface === bar.widget.surface)
        XCTAssertFalse(popout.panel.canBecomeKey)
        let sibling = try ShellRenderedWidget(
            name: "focus-sibling",
            source: "function render(ctx) return ui.box{w=30,h=20,focusable=true} end"
        )
        sibling.render(ShellBarData())
        bar.widget.surface.view.addSubview(sibling.surface.view)
        sibling.surface.view.frame = CGRect(x: 0, y: 0, width: 30, height: 20)
        sibling.surface.setVisible(true)
        host.connectSurfaceFocus(sibling.surface) { true }
        sibling.surface.focusDeclared(sibling.surface.layout.core.rootHandle)
        XCTAssertTrue(host.focusedSurface === sibling.surface)
        XCTAssertFalse(bar.widget.surface.declaredFocus)
        XCTAssertTrue(bar.panel.canBecomeKey)
        chrome.show(size: CGSize(width: 120, height: 60), level: .normal)
        XCTAssertTrue(host.focusedSurface === drawerWidget.surface)
        XCTAssertFalse(bar.panel.canBecomeKey)
        XCTAssertTrue(chrome.panel.canBecomeKey)
        XCTAssertTrue(chrome.panel.firstResponder === drawerWidget.surface.preferredFirstResponder)
        XCTAssertTrue(host.shellPreviousKeyWindow === returnWindow)
        XCTAssertTrue(host.shellPreviousFirstResponder === returnResponder)
        XCTAssertEqual(policy.activeLease?.owner, .shellIsland)
        XCTAssertEqual(leaseChanges, 1)
        chrome.close(animated: false)
        XCTAssertNil(policy.activeLease)
        XCTAssertNil(host.focusedSurface)
        XCTAssertFalse(chrome.panel.canBecomeKey)
        XCTAssertEqual(leaseChanges, 2)
    }

    func testStaleSourceCannotReleaseTransferredFocusAndActualHideReleasesIt() throws {
        let policy = FocusPolicyEngine()
        let host = host(policy)
        let first = try Fixture()
        let second = try Fixture()
        first.connect(host)
        second.connect(host)
        defer { first.close()
            second.close()
        }
        first.focus()
        let stale = first.panel.onBlur
        second.focus()
        first.widget.surface.onFocusChange?(false)
        stale?()
        XCTAssertTrue(host.focusedSurface === second.widget.surface)
        XCTAssertEqual(policy.activeLease?.owner, .shellIsland)
        XCTAssertFalse(first.panel.canBecomeKey)
        XCTAssertTrue(second.panel.canBecomeKey)
        XCTAssertFalse(OwnedWindowRegistry.shared.visibleWindows(suppressesManagedFocusRecovery: true)
            .contains { $0 === first.panel })
        XCTAssertTrue(OwnedWindowRegistry.shared.visibleWindows(suppressesManagedFocusRecovery: true)
            .contains { $0 === second.panel })
        second.widget.surface.setVisible(false)
        XCTAssertNil(host.focusedSurface)
        XCTAssertNil(policy.activeLease)
        XCTAssertFalse(second.panel.canBecomeKey)
        XCTAssertNil(host.islandInputMonitors)
    }

    func testRegistryFocusOverridePreservesSurfaceIdentityCaptureAndRegions() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let scene = SurfaceScene()
        let registry = OwnedWindowRegistry(surfaceCoordinator: SurfaceCoordinator(scene: scene))
        let region = CGRect(x: 25, y: 25, width: 12, height: 12)
        registry.register(
            fixture.panel, surfaceId: "focus-regions",
            policy: SurfacePolicy(
                kind: .shellIsland,
                hitTestPolicy: .interactive,
                capturePolicy: .excluded,
                suppressesManagedFocusRecovery: false
            ),
            regionProvider: { [region] }
        )
        let before = scene.runtimeSnapshot()
        XCTAssertEqual(registry.setManagedFocusRecoverySuppressed(true, for: fixture.panel), false)
        XCTAssertEqual(
            registry
                .visibleSurfaceIDs(kind: .shellIsland, capturePolicy: .excluded, suppressesManagedFocusRecovery: true),
            ["focus-regions"]
        )
        XCTAssertTrue(registry.contains(point: CGPoint(x: 30, y: 30)))
        XCTAssertFalse(registry.contains(point: CGPoint(x: 80, y: 30)))
        XCTAssertEqual(scene.runtimeSnapshot(), before)
        XCTAssertEqual(registry.setManagedFocusRecoverySuppressed(false, for: fixture.panel), true)
        XCTAssertEqual(
            registry
                .visibleSurfaceIDs(kind: .shellIsland, capturePolicy: .excluded, suppressesManagedFocusRecovery: false),
            ["focus-regions"]
        )
        registry.unregister(fixture.panel)
        XCTAssertNil(registry.setManagedFocusRecoverySuppressed(true, for: fixture.panel))
    }

    func testNativeEditorRemainsFirstResponderAndEscapeBypassesPanelDismissal() throws {
        let host = host(FocusPolicyEngine())
        let fixture = try Fixture(input: true)
        fixture.connect(host)
        let dismissal = PanelDismissalMonitor()
        var dismissals = 0
        dismissal.start(
            panels: [fixture.panel], isExemptWindow: { _ in false },
            shouldHandleEscape: { !fixture.widget.surface.hasFocusedTextInput }, onDismiss: { dismissals += 1 }
        )
        defer { dismissal.stop()
            fixture.close()
        }
        fixture.focus()
        XCTAssertTrue(fixture.widget.surface.hasFocusedTextInput)
        XCTAssertTrue(fixture.panel.firstResponder === fixture.widget.surface.preferredFirstResponder)
        XCTAssertTrue(fixture.panel.firstResponder is NSTextView)
        let escape = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
            windowNumber: fixture.panel.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53
        ))
        XCTAssertFalse(dismissal.handleLocalEvent(escape))
        XCTAssertFalse(fixture.widget.surface.handleDeclaredKey(escape))
        XCTAssertFalse(fixture.widget.surface.handleKey(53, shift: false))
        XCTAssertEqual(dismissals, 0)
        fixture.widget.surface.blurDeclaredFocus()
        XCTAssertTrue(dismissal.handleLocalEvent(escape))
        XCTAssertEqual(dismissals, 1)
    }

    func testRestorationRequiresActiveAppVisiblePreviousWindowAndNoForeignKeyWindow() throws {
        let source = try Fixture()
        let previous = try Fixture()
        let foreign = try Fixture()
        defer { source.close()
            previous.close()
            foreign.close()
        }
        XCTAssertTrue(ShellWidgetHost.shouldRestoreShellFocus(
            previous: previous.panel,
            current: source.panel,
            source: source.panel,
            appActive: true
        ))
        XCTAssertTrue(ShellWidgetHost.shouldRestoreShellFocus(
            previous: previous.panel,
            current: nil,
            source: source.panel,
            appActive: true
        ))
        XCTAssertFalse(ShellWidgetHost.shouldRestoreShellFocus(
            previous: previous.panel,
            current: foreign.panel,
            source: source.panel,
            appActive: true
        ))
        XCTAssertFalse(ShellWidgetHost.shouldRestoreShellFocus(
            previous: previous.panel,
            current: source.panel,
            source: source.panel,
            appActive: false
        ))
        previous.panel.orderOut(nil)
        XCTAssertFalse(ShellWidgetHost.shouldRestoreShellFocus(
            previous: previous.panel,
            current: source.panel,
            source: source.panel,
            appActive: true
        ))
    }
}
