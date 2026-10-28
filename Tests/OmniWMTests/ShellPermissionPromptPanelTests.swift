// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import SwiftUI
import XCTest

@MainActor
final class ShellPermissionPromptPanelTests: XCTestCase {
    private func network(hostCount: Int, purpose: String? = nil, source: String = "/shell/widgets/test")
        -> ShellPermissionPrompts.Request
    {
        .network(ShellNetworkApproval(
            key: .init(
                principal: ShellWidgetPrincipal(role: .bar, name: "test", source: source),
                hosts: Set((0 ..< hostCount).map { "api-\($0).example" })
            ),
            purpose: purpose
        ))
    }

    private func withPanel(
        _ request: ShellPermissionPrompts.Request,
        check: (NSPanel, NSView, CGRect) throws -> Void
    ) async throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let existing = Set(NSApp.windows.map(\.windowNumber))
        let dismiss = ShellPermissionPromptPanel.present(request, title: "Test widget") { _ in }
        defer { dismiss() }
        try await Task.sleep(for: .milliseconds(100))
        let panel = try XCTUnwrap(NSApp.windows.first {
            !existing.contains($0.windowNumber) && $0 is NSPanel && $0.isVisible
        } as? NSPanel)
        let content = try XCTUnwrap(panel.contentView)
        content.layoutSubtreeIfNeeded()
        try check(panel, content, panel.screen?.visibleFrame ?? screen.visibleFrame)
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews(in: $0) }
    }

    private func assertScrollableDetails(
        in content: NSView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let scroll = try XCTUnwrap(scrollViews(in: content).first, file: file, line: line)
        let document = try XCTUnwrap(scroll.documentView, file: file, line: line)
        let clip = scroll.contentView
        XCTAssertGreaterThan(document.bounds.height, clip.bounds.height, file: file, line: line)
        let original = clip.bounds.origin
        let bottom = document.isFlipped ? document.bounds.height - clip.bounds.height : 0
        clip.scroll(to: CGPoint(x: original.x, y: bottom))
        scroll.reflectScrolledClipView(clip)
        XCTAssertNotEqual(clip.bounds.origin, original, file: file, line: line)
        let scrollFrame = scroll.convert(scroll.bounds, to: content)
        XCTAssertTrue(content.bounds.contains(scrollFrame), file: file, line: line)
        let footerSpace = content.isFlipped ? content.bounds.maxY - scrollFrame.maxY : scrollFrame.minY
        XCTAssertGreaterThanOrEqual(
            footerSpace,
            24,
            "The decision buttons need space outside the scroll view",
            file: file,
            line: line
        )
    }

    func testSixtyHostsFitTheScreenAndScrollAboveTheDecisionButtons() async throws {
        try await withPanel(network(hostCount: 60, purpose: "Shows service status")) { panel, content, visible in
            XCTAssertLessThanOrEqual(panel.frame.height, visible.height)
            XCTAssertTrue(visible.contains(panel.frame))
            try assertScrollableDetails(in: content)
        }
    }

    func testShortNetworkPromptKeepsItsNaturalHeight() async throws {
        try await withPanel(network(hostCount: 2)) { panel, _, visible in
            XCTAssertTrue(visible.contains(panel.frame))
            XCTAssertLessThan(panel.frame.height, 400)
        }
    }

    func testLongPurposeAndSourceRemainScrollable() async throws {
        let request = network(
            hostCount: 2,
            purpose: String(repeating: "A widget's description can span several lines. ", count: 100),
            source: "/" + String(repeating: "nested-directory/", count: 80) + "widget"
        )
        try await withPanel(request) { panel, content, visible in
            XCTAssertTrue(visible.contains(panel.frame))
            try assertScrollableDetails(in: content)
        }
    }

    func testLongProgramCommandRemainsScrollable() async throws {
        let request = ShellPermissionPrompts.Request.program(ShellProviderApproval(
            principal: ShellWidgetPrincipal(role: .component, name: "test", source: "/shell/widgets/test"),
            command: ["provider"] + Array(repeating: "--long-program-argument", count: 100),
            sha256: "abc"
        ))
        try await withPanel(request) { panel, content, visible in
            XCTAssertTrue(visible.contains(panel.frame))
            try assertScrollableDetails(in: content)
        }
    }

    func testLongPromptFitsASmallerContentHeight() async throws {
        _ = NSApplication.shared
        let content = NSHostingView(rootView: ShellPermissionPromptView(
            request: network(hostCount: 60), name: "Test widget", maximumHeight: 320, answer: { _ in }
        ))
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = content
        panel.setContentSize(content.fittingSize)
        panel.orderFrontRegardless()
        defer { panel.close() }
        try await Task.sleep(for: .milliseconds(100))
        content.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(content.bounds.height, 320)
        try assertScrollableDetails(in: content)
    }
}
