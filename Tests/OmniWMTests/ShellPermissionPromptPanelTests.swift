// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import SwiftUI
import XCTest

@MainActor
final class ShellPermissionPromptPanelTests: XCTestCase {
    private static let application: NSApplication = {
        let application = NSApplication.shared
        if !application.isRunning { application.finishLaunching() }
        return application
    }()

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
        _ = Self.application
        let screen = try XCTUnwrap(NSScreen.main)
        let existing = Set(NSApp.windows.map(\.windowNumber))
        let dismiss = ShellPermissionPromptPanel.present(request, title: "Test widget") { _ in }
        defer { dismiss() }
        try await Task.sleep(for: .milliseconds(100))
        let panel = try XCTUnwrap(NSApp.windows.first {
            !existing.contains($0.windowNumber) && $0 is NSPanel && $0.isVisible
        } as? NSPanel)
        let hosting = try XCTUnwrap(panel.contentView as? NSHostingView<ShellPermissionPromptView>)
        let originalFrame = panel.frame
        let content = NSHostingView(rootView: hosting.rootView.environment(\.accessibilityEnabled, true))
        content.sizingOptions = []
        content.frame = hosting.frame
        panel.contentView = content
        try await Task.sleep(for: .milliseconds(100))
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(panel.frame, originalFrame)
        try check(panel, content, panel.screen?.visibleFrame ?? screen.visibleFrame)
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews(in: $0) }
    }

    private func decisionButtonFrames(
        in content: NSView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String: CGRect] {
        let identifiers: Set<String> = ["shell-permission-allow", "shell-permission-deny"]
        var frames: [String: CGRect] = [:]
        var pending: [AnyObject] = [content]
        var visited: Set<ObjectIdentifier> = []
        while let object = pending.popLast() {
            guard visited.insert(ObjectIdentifier(object)).inserted, let element = object as? NSObject else { continue }
            if element.responds(to: NSSelectorFromString("accessibilityIdentifier")),
               element.responds(to: NSSelectorFromString("accessibilityFrame")),
               let identifier = element.value(forKey: "accessibilityIdentifier") as? String,
               identifiers.contains(identifier),
               let frame = element.value(forKey: "accessibilityFrame") as? NSValue
            {
                frames[identifier] = frame.rectValue
            }
            if element.responds(to: NSSelectorFromString("accessibilityChildren")),
               let children = element.value(forKey: "accessibilityChildren") as? [AnyObject]
            {
                pending.append(contentsOf: children)
            }
            if let view = element as? NSView { pending.append(contentsOf: view.subviews) }
        }
        XCTAssertEqual(Set(frames.keys), identifiers, file: file, line: line)
        let window = try XCTUnwrap(content.window, file: file, line: line)
        let screen = try XCTUnwrap(window.screen, file: file, line: line)
        let visibleContent = window.convertToScreen(content.convert(content.visibleRect, to: nil))
        for (identifier, frame) in frames {
            XCTAssertFalse(frame.isEmpty, identifier, file: file, line: line)
            XCTAssertTrue(
                visibleContent.contains(frame),
                "\(identifier) must be visible in the panel",
                file: file,
                line: line
            )
            XCTAssertTrue(
                screen.visibleFrame.contains(frame),
                "\(identifier) must be on screen",
                file: file,
                line: line
            )
        }
        return frames
    }

    private func assertScrollableDetails(
        in content: NSView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let scroll = try XCTUnwrap(scrollViews(in: content).first, file: file, line: line)
        let document = try XCTUnwrap(scroll.documentView, file: file, line: line)
        let clip = scroll.contentView
        let buttonsBefore = try decisionButtonFrames(in: content, file: file, line: line)
        XCTAssertGreaterThan(document.bounds.height, clip.bounds.height, file: file, line: line)
        let original = clip.bounds.origin
        let bottom = document.isFlipped ? document.bounds.height - clip.bounds.height : 0
        clip.scroll(to: CGPoint(x: original.x, y: bottom))
        scroll.reflectScrolledClipView(clip)
        content.layoutSubtreeIfNeeded()
        XCTAssertNotEqual(clip.bounds.origin, original, file: file, line: line)
        XCTAssertEqual(
            try decisionButtonFrames(in: content, file: file, line: line),
            buttonsBefore,
            "Both decision buttons must stay fixed while the details scroll",
            file: file,
            line: line
        )
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
        _ = Self.application
        let content = NSHostingView(rootView: ShellPermissionPromptView(
            request: network(hostCount: 60), name: "Test widget", maximumHeight: 320, answer: { _ in }
        ).environment(\.accessibilityEnabled, true))
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
