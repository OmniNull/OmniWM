// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import SwiftUI
import XCTest

@MainActor
final class ShellSettingsOptionRowTests: XCTestCase {
    func testWorkspaceIndicatorChoiceTitlesRenderInChinese() throws {
        let schema = try XCTUnwrap(ShellRootSettings.load(
            "workspaces", directories: [try XCTUnwrap(ShellDefaults.bundled)]
        ))
        var option = try XCTUnwrap(schema.options["indicator"])
        let titles = ["胶囊", "下划线", "圆点", "数字", "极简"]
        XCTAssertEqual(option.choices, ["pills", "underline", "dots", "numbers", "minimal"])
        for (choice, title) in zip(option.choices, titles) {
            option.defaultValue = .string(choice)
            var expected = option
            expected.choices = titles
            expected.defaultValue = .string(title)
            XCTAssertEqual(
                try snapshot(option, key: "indicator"),
                try snapshot(expected, key: "indicator"),
                choice
            )
        }
    }

    func testOptionTitlesRenderInChineseFromTheAppAndTheStyleStrings() throws {
        let schema = try XCTUnwrap(ShellRootSettings.load(
            "workspaces", directories: [try XCTUnwrap(ShellDefaults.bundled)]
        ))
        let lake = try ShellStrings.load([try ShellStyleFixture.source("lake")], localization: chinese.identifier)
        let cases: [(ShellComponentOption, String)] = [
            (.init(kind: .boolean, title: "Show date"), "显示日期"),
            (try XCTUnwrap(schema.options["indicator"]), "工作空间指示器"),
            (
                .init(kind: .number, title: "Low battery threshold (%)", minimum: 1, maximum: 100),
                "低电量阈值 (%)"
            ),
            (.init(kind: .number, title: "Hover delay"), "悬停延迟"),
            (.init(kind: .string, title: "Initial label"), "初始标签"),
            (.init(kind: .string, title: "Selected tab color"), "选中选项卡颜色"),
            (.init(kind: .strings, title: "Component regions"), "组件区域")
        ]
        for (option, title) in cases {
            let key = option.title
            var expected = option
            expected.title = title
            let actualPixels = try snapshot(option, key: key, strings: lake)
            let expectedPixels = try snapshot(expected, key: key)
            XCTAssertEqual(actualPixels, expectedPixels, key)
        }
    }

    private let chinese = Locale(identifier: "zh-Hans")

    private func snapshot(_ option: ShellComponentOption, key: String, strings: ShellStrings = .empty) throws -> Data {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: Form {
            ShellSettingsOptionRow(key: key, option: option, value: nil, strings: strings) { _ in }
        }
        .formStyle(.grouped)
        .environment(\.locale, chinese)
        .transaction { $0.animation = nil })
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 600, height: 180),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil
            window.close()
        }
        NSApp.updateWindows()
        host.layoutSubtreeIfNeeded()
        window.display()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        let bytes = try XCTUnwrap(bitmap.bitmapData)
        let count = bitmap.bytesPerRow * bitmap.pixelsHigh
        bytes.initialize(repeating: 0, count: count)
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let pixels = Data(bytes: bytes, count: count)
        XCTAssertGreaterThan(Set(pixels).count, 8, "\(option.title): native content must render before comparison")
        return pixels
    }
}
