// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import SwiftUI
import XCTest

@MainActor
final class ShellSettingsOptionRowTests: XCTestCase {
    func testOptionTitlesRenderInChinese() throws {
        let schema = try XCTUnwrap(ShellRootSettings.load(
            "workspaces", directories: [try XCTUnwrap(ShellDefaults.bundled)]
        ))
        let omniwm = try XCTUnwrap(ShellRootSettings.load(
            "omniwm", directories: [try XCTUnwrap(ShellDefaults.bundled)]
        ))
        let cases: [(ShellComponentOption, String)] = [
            (.init(kind: .boolean, title: "Show date"), "显示日期"),
            (try XCTUnwrap(schema.options["indicator"]), "工作空间指示器"),
            (
                .init(kind: .number, title: "Low battery threshold (%)", minimum: 1, maximum: 100),
                "低电量阈值 (%)"
            ),
            (.init(kind: .number, title: "Hover delay"), "悬停延迟"),
            (.init(kind: .string, title: "Initial label"), "初始标签"),
            (try XCTUnwrap(omniwm.options["iconColor"]), "图标颜色"),
            (.init(kind: .strings, title: "Component regions"), "组件区域")
        ]
        for (option, title) in cases {
            let key = option.title
            var expected = option
            expected.title = title
            let actualPixels = try snapshot(option, key: key)
            let expectedPixels = try snapshot(expected, key: key)
            XCTAssertEqual(actualPixels, expectedPixels, key)
        }
    }

    private func snapshot(_ option: ShellComponentOption, key: String) throws -> Data {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: Form {
            ShellSettingsOptionRow(key: key, option: option, value: nil) { _ in }
        }
        .formStyle(.grouped)
        .environment(\.locale, Locale(identifier: "zh-Hans"))
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
