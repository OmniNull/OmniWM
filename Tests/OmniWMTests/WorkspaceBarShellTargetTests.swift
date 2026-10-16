// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMIPC
import SwiftUI
import XCTest

@MainActor
final class WorkspaceBarShellTargetTests: XCTestCase {
    func testShellTargetsResolveToNativeHitTargets() {
        let workspaceId = WorkspaceDescriptor.ID()
        let token = WindowToken(pid: 41, windowId: 7)
        let window = WorkspaceBarWindowItem(
            id: token,
            handle: WindowHandle(id: token),
            windowId: 7,
            appName: "Mail",
            bundleId: nil,
            icon: nil,
            isFocused: false,
            windowCount: 1,
            hiddenWindowCount: 0,
            allWindows: []
        )
        let snapshot = WorkspaceBarSnapshot(
            projection: WorkspaceBarProjection(
                items: [WorkspaceBarItem(
                    id: workspaceId,
                    name: "1",
                    rawName: "1",
                    isFocused: true,
                    tiledWindows: [window],
                    floatingWindows: []
                )],
                scratchpads: []
            ),
            backgroundOpacity: 0.6,
            barHeight: 24
        )
        let resolve = { (text: String) in
            WorkspaceBarManager.shellTarget(
                text,
                sessionToken: "session",
                snapshot: snapshot,
                workspaceId: { $0 == "1" ? workspaceId : nil }
            )
        }
        let id = IPCWindowOpaqueID.encode(pid: 41, windowId: 7, sessionToken: "session")
        let stale = IPCWindowOpaqueID.encode(pid: 41, windowId: 7, sessionToken: "other")

        XCTAssertEqual(resolve("workspace 1"), .workspace(workspaceId))
        XCTAssertEqual(resolve("scratchpad 2"), .scratchpad(2))
        XCTAssertEqual(resolve("window \(id)"), .window(workspaceId, token))
        XCTAssertNil(resolve("window \(stale)"))
        XCTAssertNil(resolve("workspace 9"))
        XCTAssertNil(resolve("everything"))
    }

    func testABarWithoutShellWidgetsOnlyMeasuresItsPadding() {
        let snapshot = WorkspaceBarSnapshot(
            projection: WorkspaceBarProjection(
                items: [WorkspaceBarItem(
                    id: WorkspaceDescriptor.ID(),
                    name: "1",
                    rawName: "1",
                    isFocused: true,
                    tiledWindows: [],
                    floatingWindows: []
                )],
                scratchpads: [WorkspaceBarScratchpadItem(index: 1, label: nil, windows: [], isVisible: true)]
            ),
            backgroundOpacity: 1,
            barHeight: 24
        )
        let view = NSHostingView(rootView: WorkspaceBarMeasurementView(snapshot: snapshot))
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.fittingSize.width, 8, accuracy: 0.5)
    }

    func testBarStyleClicksMapToNativeBarActions() throws {
        let id = IPCWindowOpaqueID.encode(pid: 41, windowId: 7, sessionToken: "session")
        let click = { (text: String) in
            ShellRequest(text).flatMap { WorkspaceBarManager.barClick(for: $0, sessionToken: "session") }
        }
        XCTAssertEqual(click("window focus \(id)"), .focusWindow(WindowToken(pid: 41, windowId: 7)))
        XCTAssertEqual(click("switch-workspace 3"), .focusWorkspace(rawName: "3"))
        XCTAssertEqual(click("scratchpad toggle 2"), try .toggleScratchpad(XCTUnwrap(ScratchpadIndex(2))))
        XCTAssertNil(click("window close \(id)"))
        XCTAssertNil(click("switch-workspace next"))
        XCTAssertNil(click("window focus \(IPCWindowOpaqueID.encode(pid: 41, windowId: 7, sessionToken: "other"))"))
    }

    func testAPaletteFillPaintsTheBarAndItsBorder() throws {
        let fill = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        let border = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        var theme = ShellTheme.native
        for (role, color) in [(ShellRole.surface, fill), (.border, border)] {
            theme.light[role.rawValue] = color
            theme.dark[role.rawValue] = color
        }
        let painted = try renderedBar(
            fill: ShellThemeColor("surface", theme: theme),
            border: ShellThemeColor("border", theme: theme)
        )
        XCTAssertGreaterThan(painted.center.redComponent - painted.center.blueComponent, 0.7)
        XCTAssertGreaterThan(painted.edge.blueComponent - painted.edge.redComponent, 0.7)

        let plain = try renderedBar(
            fill: ShellThemeColor("surface", theme: theme),
            border: ShellThemeColor("border", theme: theme),
            transparent: true
        )
        XCTAssertEqual(plain.center.alphaComponent, 0, accuracy: 0.02)
        XCTAssertEqual(plain.edge.alphaComponent, 0, accuracy: 0.02)

        let faded = try renderedBar(
            fill: ShellThemeColor("surface/0.5", theme: theme),
            border: nil,
            opacity: 0.4
        )
        XCTAssertEqual(faded.center.alphaComponent, 0.2, accuracy: 0.02)
        XCTAssertGreaterThan(faded.center.redComponent - faded.center.blueComponent, 0.7)

        let black = try renderedBar(
            fill: ShellThemeColor("surface", theme: theme),
            border: ShellThemeColor("border", theme: theme),
            opacity: 0,
            transparent: true,
            solidBlack: true
        )
        for color in [black.center, black.edge] {
            XCTAssertEqual(color.redComponent, 0, accuracy: 0.02)
            XCTAssertEqual(color.greenComponent, 0, accuracy: 0.02)
            XCTAssertEqual(color.blueComponent, 0, accuracy: 0.02)
            XCTAssertEqual(color.alphaComponent, 1, accuracy: 0.02)
        }
    }

    private func renderedBar(
        fill: ShellThemeColor?,
        border: ShellThemeColor?,
        opacity: Double = 1,
        transparent: Bool = false,
        solidBlack: Bool = false
    ) throws -> (center: NSColor, edge: NSColor) {
        let model = WorkspaceBarModel(snapshot: WorkspaceBarSnapshot(
            projection: WorkspaceBarProjection(items: [], scratchpads: []),
            backgroundOpacity: opacity,
            transparentBackground: transparent,
            solidBlackBackground: solidBlack,
            barHeight: 24,
            barFill: fill,
            barBorder: border
        ))
        model.zones = WorkspaceBarZones(notch: nil, mode: .rightOfNotch)
        let frame = CGRect(x: 0, y: 0, width: 80, height: 24)
        let hosting = NSHostingView(rootView: WorkspaceBarView(
            model: model,
            motionPolicy: MotionPolicy(animationsEnabled: false)
        )
        .frame(width: frame.width, height: frame.height))
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let pixel = { (x: Int) in
            try XCTUnwrap(bitmap.colorAt(x: x, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        }
        let colors = try (center: pixel(bitmap.pixelsWide / 2), edge: pixel(0))
        withExtendedLifetime(window) {}
        return colors
    }
}
