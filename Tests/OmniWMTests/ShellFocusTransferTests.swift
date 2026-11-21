// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class ShellFocusTransferTests: XCTestCase {
    @MainActor
    private final class Fixture {
        let widget: ShellRenderedWidget
        let panel: ShellFocusPanel

        init(input: Bool = false) throws {
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
            panel = ShellPopoutPanel(content: widget.surface.view)
            panel.setFrame(CGRect(x: 20, y: 20, width: 120, height: 60), display: false)
            widget.surface.view.frame = CGRect(x: 0, y: 0, width: 120, height: 60)
            panel.orderFrontRegardless()
            widget.surface.setVisible(true)
            OwnedWindowRegistry.shared.register(
                panel, surfaceId: "focus-test-\(ObjectIdentifier(panel))",
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
