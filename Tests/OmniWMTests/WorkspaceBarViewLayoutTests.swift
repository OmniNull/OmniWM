// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMShellCore
import SwiftUI
import XCTest

private struct NarrowWidthLayout: Layout {
    let width: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        subviews.first?.sizeThatFits(
            ProposedViewSize(width: width, height: proposal.height)
        ) ?? .zero
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        subviews.first?.place(
            at: CGPoint(x: bounds.minX, y: bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: width, height: bounds.height)
        )
    }
}

@MainActor
final class WorkspaceBarViewLayoutTests: XCTestCase {
    private func item(
        _ id: String,
        name: String = "App",
        count: Int = 1,
        hidden: Int = 0,
        focused: Bool = false,
        floating: Bool = false,
        titles: [String]? = nil
    ) -> ShellBarItem {
        let windows = (0 ..< count).map { index in
            ShellBarWindow(
                id: "\(id)_\(index)",
                title: titles?[index] ?? "Window \(index + 1)",
                focused: focused && index == 0,
                hidden: index < hidden
            )
        }
        return ShellBarItem(
            id: id, bundle: "com.example.app", name: name, focused: focused, count: count, hidden: hidden,
            floating: floating, windows: windows
        )
    }

    private func bar(
        _ workspaces: [ShellBarWorkspace] = [],
        scratchpads: [ShellBarScratchpad] = [],
        style: (inout ShellBarStyle) -> Void = { _ in }
    ) -> ShellBarData {
        var data = ShellBarData()
        style(&data.style)
        data.workspaces = workspaces
        data.scratchpads = scratchpads
        return data
    }

    private func icons(_ widget: ShellRenderedWidget) -> [TreeNode] {
        widget.tree().filter { $0.kind == .image }
    }

    private func symbols(_ widget: ShellRenderedWidget) -> [String] {
        widget.tree().filter { $0.kind == .symbol }.map { widget.text.string($0.content.text) }
    }

    private func role(_ color: OmniWMShellCore.Color) -> ShellRole? {
        color.role == 0 ? nil : ShellRole(rawValue: Int(color.role & 0xFF) - 1)
    }

    private func l10n(_ key: String, _ arguments: ShellLocalizer.Argument...) -> String {
        ShellLocalizer.string(key, arguments)
    }

    func testConfiguredAndDefaultInactiveIconOpacity() throws {
        let widget = try ShellRenderedWidget("workspaces")
        let workspaces = [
            ShellBarWorkspace(id: "1", name: "1", focused: true, windows: [item("a", focused: true), item("b")]),
            ShellBarWorkspace(id: "2", name: "2", focused: false, windows: [item("c")])
        ]
        widget.render(bar(workspaces))
        XCTAssertEqual(icons(widget).map(\.paint.opacity), [1, 0.4, 0.5])
        widget.render(bar(workspaces) { $0.inactive = 0.27 })
        XCTAssertEqual(icons(widget).map(\.paint.opacity), [1, 0.27, 0.27])
    }

    func testScratchpadIconOpacityDefaultsOverridesAndFocus() throws {
        let widget = try ShellRenderedWidget("scratchpads")
        let scratchpad = ShellBarScratchpad(
            id: 1, name: "Notes", focused: false, revealed: false, visible: true,
            windows: [item("a"), item("b", focused: true)]
        )
        widget.render(bar(scratchpads: [scratchpad]))
        XCTAssertEqual(icons(widget).map(\.paint.opacity), [0.82, 1])
        widget.render(bar(scratchpads: [scratchpad]) { $0.inactive = 0.31 })
        XCTAssertEqual(icons(widget).map(\.paint.opacity), [0.31, 1])
    }

    func testConfiguredInactiveOpacityPreservesHiddenAppStatus() throws {
        let widget = try ShellRenderedWidget("workspaces")
        widget.render(bar([ShellBarWorkspace(id: "1", name: "1", focused: false, windows: [
            item("mail", name: "Mail", count: 2, hidden: 2, floating: true)
        ])]) { $0.inactive = 0.2 })
        let icon = try XCTUnwrap(icons(widget).first)
        XCTAssertEqual(icon.paint.opacity, 0.9)
        XCTAssertEqual(role(icon.content.color), .error)
        XCTAssertTrue(symbols(widget).contains("eye.slash.fill"))
    }

    func testFocusedScratchpadRendersAnAccentOutlineOnlyWithAccents() throws {
        let widget = try ShellRenderedWidget("scratchpads")
        for compact in [false, true] {
            let scratchpad = ShellBarScratchpad(
                id: 1, name: "Notes", focused: true, revealed: false, visible: true,
                windows: [item("a", focused: true)], compact: compact
            )
            for accents in [false, true] {
                widget.render(bar(scratchpads: [scratchpad]) {
                    $0.accents = accents
                    $0.backgrounds = false
                })
                let pill = try XCTUnwrap(widget.tree()
                    .first { widget.text.string($0.content.target) == "scratchpad 1" })
                XCTAssertEqual(role(pill.paint.stroke) == .accent, accents, "compact \(compact)")
            }
        }
    }

    func testSnapshotCopiesKeepTheBackgroundAndSolidBlackPrecedence() {
        let snapshot = WorkspaceBarSnapshot(
            projection: WorkspaceBarProjection(items: [], scratchpads: []),
            backgroundOpacity: 0.6,
            transparentBackground: true,
            solidBlackBackground: true,
            barHeight: 24
        )
        let copy = snapshot.replacingShellWidgets([])
        XCTAssertEqual(copy, snapshot)
        XCTAssertEqual(copy.backgroundStyle, .solidBlack)
    }

    func testWindowIconsDistinguishAppHiddenAndPartiallyHiddenGroups() throws {
        let widget = try ShellRenderedWidget("workspaces")
        widget.render(bar([ShellBarWorkspace(id: "1", name: "1", focused: true, windows: [
            item("mail", name: "Mail", hidden: 1, focused: true),
            item("web", name: "Browser", count: 3, hidden: 1, floating: true)
        ])]))
        let icons = icons(widget)
        XCTAssertEqual(icons.map(\.paint.opacity), [0.9, 0.4])
        XCTAssertEqual(icons.map { role($0.content.color) }, [.error, nil])
        XCTAssertEqual(symbols(widget).filter { $0.hasPrefix("eye.slash") }, ["eye.slash.fill", "eye.slash"])
        let helps = widget.tree().map { widget.text.string($0.content.help) }
        XCTAssertTrue(helps.contains(l10n("%@ window", .text("Mail"))))
        XCTAssertTrue(helps.contains(l10n("%@, %lld floating windows", .text("Browser"), .number(3))))
    }

    func testVisibleWindowsFocusDirectlyAndHiddenGroupsShowTheFullIndicator() throws {
        let widget = try ShellRenderedWidget("workspaces")
        widget.render(bar([ShellBarWorkspace(id: "2", name: "2", focused: false, windows: [
            item("notes", name: "Notes"),
            item("term", name: "Terminal", count: 2, hidden: 2)
        ])]))
        let first = try XCTUnwrap(icons(widget).first)
        XCTAssertEqual(first.paint.opacity, 0.5)
        XCTAssertNil(role(first.content.color))
        XCTAssertEqual(symbols(widget).filter { $0.hasPrefix("eye.slash") }, ["eye.slash.fill"])
        let actions = widget.tree().filter { $0.content.action != 0 }.map { widget.text.string($0.content.action) }
        XCTAssertTrue(actions.contains("window focus notes"))
        XCTAssertFalse(actions.contains("window focus term"))
    }

    func testWindowListRowsDescribeTheRevealAction() throws {
        let widget = try ShellRenderedWidget("workspaces")
        widget.render(bar([ShellBarWorkspace(id: "1", name: "1", focused: true, windows: [
            item("mail", name: "Mail", count: 2, hidden: 1, focused: true, titles: ["Compose", "Inbox"])
        ])]))
        let group = try XCTUnwrap(widget.tree().first { widget.text.string($0.content.target) == "window mail" })
        widget.invoke(group.content.action)
        let rows = widget.renderPopout().map { widget.text.string($0.content.help) }.filter { !$0.isEmpty }
        XCTAssertEqual(rows, [l10n("Unhide and focus %@", .text("Compose")), l10n("Focus %@", .text("Inbox"))])
    }

    func testThePickerWrapsFullTitlesScrollsToItsLastRowAndClosesWithItsGroup() throws {
        let widget = try ShellRenderedWidget("workspaces")
        let titles = (1 ... 20).map { "Window \($0) with a title long enough to need a second line" }
        let group = { (count: Int, style: @escaping (inout ShellBarStyle) -> Void) in
            self.bar([ShellBarWorkspace(id: "1", name: "1", focused: true, windows: [
                self.item("web", name: "Browser", count: count, focused: true, titles: titles)
            ])], style: style)
        }
        widget.render(group(20) { _ in })
        let icon = try XCTUnwrap(widget.tree().first { widget.text.string($0.content.target) == "window web" })
        widget.invoke(icon.content.action)
        widget.layoutPopout()
        let rows = widget.renderPopout().filter { titles.contains(widget.text.string($0.content.text)) }
        XCTAssertEqual(rows.count, 20)
        XCTAssertTrue(rows.allSatisfy { $0.content.lines == 255 && $0.content.maxWidth >= 240 })
        XCTAssertEqual(
            rows.map { role($0.content.color) },
            [.foreground] + Array(repeating: .secondaryForeground, count: 19)
        )

        let natural = widget.surface.naturalSize
        widget.surface.setRootLimit(CGSize(width: natural.width, height: 200))
        XCTAssertEqual(widget.surface.size.height, 200)
        XCTAssertTrue(widget.surface.scroll(
            at: CGPoint(x: 50, y: 150),
            event: ShellEvent(button: .none),
            content: CGPoint(x: 0, y: 100_000)
        ))
        widget.surface.press(at: CGPoint(x: 50, y: 195))
        widget.surface.release(at: CGPoint(x: 50, y: 195))
        XCTAssertEqual(widget.clicks.last?.action, "window focus web_19")

        widget.render(group(20) { $0.textColor = "#FF0000" })
        XCTAssertTrue(widget.renderPopout().filter { titles.contains(widget.text.string($0.content.text)) }
            .allSatisfy { role($0.content.color) == .foreground })
        widget.render(group(1) { _ in })
        XCTAssertTrue(widget.renderPopout().isEmpty || widget.renderPopout().allSatisfy { $0.content.text == 0 })
    }

    func testSystemStatsFitsAndScrollsInsideASmallSidePopupArea() throws {
        let widget = try ShellRenderedWidget("system-stats")
        widget.set("system") { writer in
            ShellSystemData(
                memoryUsed: 8 << 30,
                memoryTotal: 16 << 30,
                pressure: .normal,
                diskUsed: 400_000_000_000,
                diskTotal: 1_000_000_000_000,
                uptime: 3600,
                host: SystemStatsHostInfo(
                    chip: "Test chip",
                    modelIdentifier: "Test model",
                    osVersion: "Test OS",
                    hostname: "Test host"
                ),
                displays: [ShellSystemDisplay(width: 380, height: 180, refresh: 60)]
            ).write(into: &writer)
        }
        widget.set("cpu") { $0.number(25) }
        widget.layoutPopout()
        let natural = widget.surface.naturalSize
        let visible = CGRect(x: -800, y: -500, width: 380, height: 180)
        for position in [WorkspaceBarPosition.left, .right] {
            let bar = CGRect(
                x: position == .left ? visible.minX : visible.maxX - 48,
                y: visible.minY, width: 48, height: visible.height
            )
            let anchor = ShellAnchor(
                frame: CGRect(x: bar.minX + 4, y: bar.midY - 11, width: 40, height: 22),
                level: .statusBar,
                container: bar
            )
            let attachment = ShellPopout.attachment(anchor: anchor, edge: position.popupEdge, screen: visible)
            let fitted = ShellPopout.fitted(natural, attachment: attachment, visibleFrame: visible)
            let frame = attachment.frame(size: fitted, visibleFrame: visible)
            XCTAssertTrue(visible.contains(frame))
            XCTAssertFalse(frame.intersects(bar))
            XCTAssertLessThan(fitted.height, natural.height)

            widget.surface.setRootLimit(fitted)
            XCTAssertEqual(widget.surface.size, fitted)
            XCTAssertTrue(widget.surface.scroll(
                at: CGPoint(x: 20, y: 20),
                event: ShellEvent(button: .none),
                content: CGPoint(x: 0, y: 10_000)
            ))
            ShellLayerScene.engineQueue.sync {}
            let scrolled = try XCTUnwrap(widget.layers().first { $0.bounds.origin.y > 0 })
            let bottom = try XCTUnwrap(scrolled.sublayers?.map(\.frame.maxY).max())
            XCTAssertEqual(scrolled.bounds.origin.y, bottom + 16 - fitted.height, accuracy: 0.5)
            widget.surface.setRootLimit(nil)
            XCTAssertTrue(widget.surface.scroll(
                at: CGPoint(x: 20, y: 20),
                event: ShellEvent(button: .none),
                content: CGPoint(x: 0, y: -10_000)
            ))
            XCTAssertEqual(widget.surface.size, natural)
        }
    }

    func testFocusedItemsKeepTheirScaleWhileHovered() throws {
        let workspaces = try ShellRenderedWidget("workspaces")
        workspaces.render(bar([ShellBarWorkspace(id: "1", name: "1", focused: true, windows: [
            item("mail", name: "Mail", focused: true),
            item("web", name: "Browser")
        ])]))
        let scales = { (target: String) -> (Float, Float)? in
            workspaces.tree().first { workspaces.text.string($0.content.target) == target }
                .map { ($0.paint.scale, $0.content.hoverScale) }
        }
        XCTAssertEqual(scales("window mail")?.0, 1.1)
        XCTAssertEqual(scales("window mail")?.1, 1.1)
        XCTAssertEqual(scales("window web")?.0, 1)
        XCTAssertEqual(scales("window web")?.1, 1.05)

        let scratchpads = try ShellRenderedWidget("scratchpads")
        scratchpads.render(bar(scratchpads: [
            ShellBarScratchpad(id: 1, name: "Notes", focused: true, revealed: true, visible: true, windows: []),
            ShellBarScratchpad(id: 2, name: "Mail", focused: false, revealed: false, visible: false, windows: [])
        ]))
        let hover = { (target: String) in
            scratchpads.tree().first { scratchpads.text.string($0.content.target) == target }?.content.hoverScale
        }
        XCTAssertEqual(hover("scratchpad 1"), 1.04)
        XCTAssertEqual(hover("scratchpad 2"), 1.03)
    }

    func testRenameAnchorsOnTheWorkspaceLabelWhenOneIsShown() throws {
        let widget = try ShellRenderedWidget("workspaces")
        var events: [ShellMenuEvent] = []
        widget.surface.onMenu = { events.append($0) }
        for labels in [true, false] {
            widget.render(bar([ShellBarWorkspace(id: "1", name: "Mail", focused: true, windows: [
                item("mail", name: "Mail", focused: true)
            ])]) { $0.labels = labels })
            XCTAssertTrue(widget.surface.openMenu(at: CGPoint(x: 8, y: 10)))
        }
        XCTAssertEqual(events.count, 2)
        let label = try XCTUnwrap(events.first?.label)
        XCTAssertLessThan(label.width, try XCTUnwrap(events.first?.anchor.frame.width))
        XCTAssertNil(events.last?.label)
    }

    func testScratchpadSizesKeepTheirFractionsAtCustomBarHeights() throws {
        let widget = try ShellRenderedWidget("scratchpads")
        let sizes = { (height: CGFloat) -> (text: Float, symbol: Float) in
            widget.render(self.bar(scratchpads: [
                ShellBarScratchpad(id: 1, name: "Notes", focused: false, revealed: false, visible: true, windows: [])
            ]) { $0.height = height })
            let nodes = widget.tree()
            let label = nodes.first { $0.kind == .label && widget.text.string($0.content.text) == "Notes" }
            let tray = nodes.first { $0.kind == .symbol && widget.text.string($0.content.text) == "tray.fill" }
            return (
                Float(CTFontGetSize(ShellTextStyle.font(for: label?.content.style ?? 0))),
                ShellTextStyle.symbolSize(for: tray?.content.style ?? 0)
            )
        }
        let custom = sizes(28)
        XCTAssertEqual(custom.text, 10.8, accuracy: 0.0001)
        XCTAssertEqual(custom.symbol, 11.52, accuracy: 0.0001)
        let standard = sizes(24)
        XCTAssertEqual(standard.text, 9)
        XCTAssertEqual(standard.symbol, 10)
    }

    func testHiddenIndicatorsKeepTheWorkspacesWidth() throws {
        let widget = try ShellRenderedWidget("workspaces")
        let sizes = [0, 1, 3].map { hidden in
            widget.render(bar([ShellBarWorkspace(id: "1", name: "1", focused: true, windows: [
                item("web", name: "Browser", count: 3, hidden: hidden)
            ])]))
            return widget.surface.size
        }
        XCTAssertEqual(sizes[1], sizes[0])
        XCTAssertEqual(sizes[2], sizes[0])
    }

    func testShellSlotsKeepTheirWidthUnderANarrowProposal() {
        for width in [CGFloat(60), 120, 240] {
            let snapshot = WorkspaceBarSnapshot(
                projection: WorkspaceBarProjection(items: [], scratchpads: []),
                backgroundOpacity: 0.6,
                barHeight: 24,
                shellWidgets: [WorkspaceBarShellWidget(
                    id: "workspaces",
                    size: CGSize(width: width, height: 20),
                    lane: .leading
                )]
            )
            let measurement = NSHostingView(rootView: WorkspaceBarMeasurementView(snapshot: snapshot))
            let narrow = NSHostingView(rootView: NarrowWidthLayout(width: 40) {
                WorkspaceBarView(
                    model: WorkspaceBarModel(snapshot: snapshot),
                    motionPolicy: MotionPolicy(animationsEnabled: false)
                )
            })
            measurement.layoutSubtreeIfNeeded()
            narrow.layoutSubtreeIfNeeded()
            XCTAssertEqual(measurement.fittingSize.width, width + 8, accuracy: 0.5)
            XCTAssertEqual(narrow.fittingSize.width, measurement.fittingSize.width, accuracy: 0.5)
            XCTAssertEqual(narrow.fittingSize.height, 24)
        }
    }

    func testLongRevealedScratchpadFallsBackToAllCompactWithinSplitSegment() throws {
        let scratchpads = (1 ... 10).map { index in
            WorkspaceBarScratchpadItem(
                index: index,
                label: index == 1 ? String(repeating: "Long revealed scratchpad ", count: 20) : nil,
                windows: (0 ..< 5).map {
                    makeWindowItem(
                        appName: "App \($0)",
                        windowCount: 1,
                        hiddenWindowCount: 0,
                        tokenOffset: index * 100 + $0
                    )
                },
                isVisible: false,
                isRevealed: index == 1
            )
        }
        let result = try splitCompaction(scratchpads)
        XCTAssertEqual(result.compacted, Set(1 ... 10))
        XCTAssertLessThanOrEqual(result.compact.rendered, result.availableWidth)
    }

    func testDefaultScratchpadsCompactBeforeSplitPanelClips() throws {
        let scratchpads = (1 ... 10).map { index in
            WorkspaceBarScratchpadItem(
                index: index,
                label: nil,
                windows: [makeWindowItem(appName: "App", windowCount: 1, hiddenWindowCount: 0, tokenOffset: index)],
                isVisible: false
            )
        }
        let result = try splitCompaction(scratchpads)
        XCTAssertGreaterThan(result.expanded.estimated, result.availableWidth)
        XCTAssertLessThanOrEqual(result.expanded.rendered, result.expanded.estimated)
        XCTAssertEqual(result.compacted, Set(1 ... 10))
        XCTAssertLessThanOrEqual(result.compact.rendered, result.availableWidth)
    }

    func testMixedScratchpadsCompactBeforeFractionalRoundingClips() throws {
        let label = "A practical scratchpad label for notes and terminal work. A practica"
        let scratchpads = (1 ... 8).map { index in
            WorkspaceBarScratchpadItem(
                index: index,
                label: index == 1 ? label : nil,
                windows: [makeWindowItem(appName: "App", windowCount: 1, hiddenWindowCount: 0, tokenOffset: index)],
                isVisible: false,
                isRevealed: index == 1
            )
        }
        let result = try splitCompaction(scratchpads)
        XCTAssertGreaterThan(result.mixed.estimated, result.availableWidth)
        XCTAssertLessThanOrEqual(result.mixed.rendered, result.mixed.estimated)
        XCTAssertEqual(result.compacted, Set(1 ... 8))
        XCTAssertLessThanOrEqual(result.compact.rendered, result.availableWidth)
    }

    func testImpossibleScratchpadWidthUsesAllCompactAsTheFloor() {
        let scratchpads = (1 ... 10).map { index in
            WorkspaceBarScratchpadItem(
                index: index,
                label: index == 1 ? String(repeating: "Long label ", count: 20) : nil,
                windows: [
                    makeWindowItem(
                        appName: "App",
                        windowCount: 1,
                        hiddenWindowCount: 0,
                        tokenOffset: index
                    )
                ],
                isVisible: false,
                isRevealed: index == 1
            )
        }

        let compacted = WorkspaceBarScratchpadLayout.compactedItems(
            scratchpads,
            availableWidth: 40,
            baseWidth: 100,
            barHeight: 24,
            hasAdjacentContent: true
        )

        XCTAssertTrue(compacted.allSatisfy { $0.presentation == .compact })
        XCTAssertGreaterThan(
            100 + 8 + WorkspaceBarScratchpadLayout.estimatedWidth(of: compacted, barHeight: 24),
            40
        )
    }

    func testVerticalWidgetsStackWithinTheBarThickness() throws {
        let workspaces = try ShellRenderedWidget("workspaces")
        let scratchpads = try ShellRenderedWidget("scratchpads")
        let data = bar(
            [ShellBarWorkspace(id: "1", name: "Long workspace label", focused: true, windows: [
                item("a"), item("b"), item("c", floating: true), item("d", floating: true)
            ])],
            scratchpads: [ShellBarScratchpad(
                id: 1, name: "Long scratchpad label", focused: false, revealed: false, visible: true,
                windows: [item("a"), item("b"), item("c"), item("d")]
            )]
        ) {
            $0.height = 32
            $0.vertical = true
        }
        workspaces.render(data)
        scratchpads.render(data)
        XCTAssertLessThanOrEqual(workspaces.surface.size.width, 28)
        XCTAssertGreaterThan(workspaces.surface.size.height, 100)
        XCTAssertLessThanOrEqual(scratchpads.surface.size.width, 28)
        XCTAssertGreaterThan(scratchpads.surface.size.height, 32)
    }

    private func makeWindowItem(
        appName: String,
        windowCount: Int,
        hiddenWindowCount: Int,
        isFocused: Bool = false,
        tokenOffset: Int = 0
    ) -> WorkspaceBarWindowItem {
        let infos = (0 ..< windowCount).map { index in
            let token = WindowToken(
                pid: 42 + Int32(tokenOffset + index),
                windowId: tokenOffset + index + 1
            )
            return WorkspaceBarWindowInfo(
                id: token,
                handle: WindowHandle(id: token),
                windowId: token.windowId,
                title: "Window \(index + 1)",
                isFocused: isFocused && index == 0,
                isAppHidden: index < hiddenWindowCount
            )
        }
        let first = infos[0]
        return WorkspaceBarWindowItem(
            id: first.id,
            handle: first.handle,
            windowId: first.windowId,
            appName: appName,
            bundleId: nil,
            icon: nil,
            isFocused: isFocused,
            windowCount: windowCount,
            hiddenWindowCount: hiddenWindowCount,
            allWindows: infos
        )
    }

    private func splitMonitor() -> Monitor {
        Monitor(
            id: Monitor.ID(displayId: 7_001),
            displayId: 7_001,
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
            hasNotch: true,
            notchRange: 656 ... 856,
            name: "Test"
        )
    }

    private func splitBarSettings() -> ResolvedBarSettings {
        ResolvedBarSettings(
            enabled: true,
            showLabels: true,
            showFloatingWindows: false,
            deduplicateAppIcons: false,
            hideEmptyWorkspaces: false,
            excludedBundleIDs: [],
            reserveLayoutSpace: false,
            notchMode: .splitActiveLeft,
            notchActiveZoneWidth: 180,
            systemStatsButton: false,
            position: .overlappingMenuBar,
            windowLevel: .popup,
            height: 24,
            backgroundOpacity: 0.1,
            inactiveIconOpacity: nil,
            transparentBackground: false,
            solidBlackBackground: false,
            showItemBackgrounds: true,
            showAccentHighlights: true,
            xOffset: 0,
            yOffset: 0,
            accentColor: nil,
            textColor: nil
        )
    }

    private func splitCompaction(
        _ scratchpads: [WorkspaceBarScratchpadItem]
    ) throws -> (
        compacted: Set<Int>,
        availableWidth: CGFloat,
        expanded: (estimated: CGFloat, rendered: CGFloat),
        mixed: (estimated: CGFloat, rendered: CGFloat),
        compact: (estimated: CGFloat, rendered: CGFloat)
    ) {
        let monitor = splitMonitor()
        let resolved = splitBarSettings()
        let availableWidth = WorkspaceBarInstance.scratchpadWidth(
            on: .secondary,
            geometry: WorkspaceBarGeometry.resolve(monitor: monitor, resolved: resolved, isVisible: true),
            monitor: monitor,
            resolved: resolved
        )
        let compacted = WorkspaceBarManager.compactScratchpads(
            WorkspaceBarSnapshot(
                projection: WorkspaceBarProjection(items: [], scratchpads: scratchpads),
                backgroundOpacity: 0.6,
                barHeight: 24
            ),
            beside: [],
            availableWidth: availableWidth
        )
        let widget = try ShellRenderedWidget("scratchpads")
        func widths(_ compact: (WorkspaceBarScratchpadItem) -> Bool) -> (estimated: CGFloat, rendered: CGFloat) {
            let presented = scratchpads.map { $0.presented(as: compact($0) ? .compact : .expanded) }
            widget.render(bar(scratchpads: presented.map { scratchpad in
                ShellBarScratchpad(
                    id: scratchpad.index,
                    name: scratchpad.name,
                    focused: scratchpad.isFocused,
                    revealed: scratchpad.isRevealed,
                    visible: scratchpad.isVisible,
                    windows: scratchpad.windows.map {
                        item("ow_\($0.windowId)", name: $0.appName, count: $0.windowCount, hidden: $0.hiddenWindowCount)
                    },
                    compact: scratchpad.presentation == .compact
                )
            }))
            return (
                8 + WorkspaceBarScratchpadLayout.estimatedWidth(of: presented, barHeight: 24),
                8 + widget.surface.size.width
            )
        }
        return (
            compacted,
            availableWidth,
            widths { _ in false },
            widths { !$0.isRevealed },
            widths { compacted.contains($0.index) }
        )
    }
}
