// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class ShellWidgetSettingsModelTests: XCTestCase {
    func testChoiceTitlesUseRequestedLocaleAndKeepFallbacks() {
        let choices = [
            ("icon_and_text", "Icon and Title", "图标和标题"),
            ("icon_only", "Icon Only", "仅图标"),
            ("text_only", "Title Only", "仅标题"),
            ("meters", "Meters", "条形图"),
            ("gauge", "Gauges", "仪表盘"),
            ("graph", "Graphs", "曲线图"),
            ("beside", "Beside Icon", "图标旁"),
            ("inside", "Inside Icon", "图标内"),
            ("off", "Off", "关闭"),
            ("pills", "Pills", "胶囊"),
            ("underline", "Underline", "下划线"),
            ("dots", "Dots", "圆点"),
            ("numbers", "Numbers", "数字"),
            ("minimal", "Minimal", "极简"),
            ("solid", "Solid", "纯色"),
            ("translucent", "Translucent", "半透明"),
            ("up", "Up", "向上"),
            ("down", "Down", "下"),
            ("left", "Left", "左边"),
            ("right", "Right", "右边"),
            ("both", "Both", "两者"),
            ("pointer", "Pointer", "指针"),
            ("scroll", "Scroll", "滚动"),
            ("overview", "Overview", "概览"),
            ("audio", "Audio", "音频"),
            ("media", "Media", "媒体"),
            ("calendar", "Calendar", "日历"),
            ("weather", "Weather", "天气"),
            ("system", "System", "系统"),
            ("commands", "Commands", "命令"),
            ("windows", "Windows", "窗口"),
            ("menu", "Menu", "菜单"),
            ("clipboard", "Clipboard", "剪贴板"),
            ("applications", "Applications", "应用程序"),
            ("files", "Files", "文件")
        ]
        let chinese = Locale(identifier: "zh-Hans")
        for (value, english, translated) in choices {
            XCTAssertEqual(ShellWidgetSettingsModel.title(value, locale: chinese), translated, value)
            XCTAssertEqual(ShellWidgetSettingsModel.title(value, locale: Locale(identifier: "en")), english, value)
        }
        XCTAssertEqual(ShellWidgetSettingsModel.title("pills", locale: Locale(identifier: "fr")), "Pills")
        for (value, title) in [
            ("png", "Png"), ("jpeg", "Jpeg"), ("tiff", "Tiff"),
            ("my_custom-choice", "MY Custom Choice"), ("Custom %@ threshold 75%", "Custom %@ threshold 75%")
        ] {
            XCTAssertEqual(ShellWidgetSettingsModel.title(value, locale: chinese), title, value)
        }
    }

    func testWidgetSettingsDecodeWithoutDiscardingStructuredWorldClockLocations() throws {
        let values = ShellServiceValue.object([
            "bar": .number(2),
            "zones": .array([
                .object(["label": .text("Toronto"), "zone": .text("America/Toronto")]),
                .object(["label": .text("Tokyo"), "zone": .text("Asia/Tokyo")])
            ])
        ])
        var writer = ShellValueWriter()
        values.write(to: &writer)
        var config = ShellConfig()
        config.widgetSettings["world-clock"] = writer.bytes
        XCTAssertEqual(ShellWidgetSettingsModel.values(widget: "world-clock", config: config)["bar"], .number(2))
        let clocks = ShellWidgetSettingsModel.clocks(config: config)
        XCTAssertEqual(clocks.map(\.label), ["Toronto", "Tokyo"])
        XCTAssertEqual(clocks.map(\.zone), ["America/Toronto", "Asia/Tokyo"])
        XCTAssertTrue(ShellWidgetSettingsModel.validClocks(clocks))
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(clocks)) as? [[String: String]]
        XCTAssertEqual(
            encoded,
            [["label": "Toronto", "zone": "America/Toronto"], ["label": "Tokyo", "zone": "Asia/Tokyo"]]
        )
    }

    func testWorldClockValidationRejectsEmptyOrInvalidZones() {
        XCTAssertFalse(ShellWidgetSettingsModel.validClocks([]))
        XCTAssertFalse(ShellWidgetSettingsModel.validClocks([.init(label: "", zone: "Europe/London")]))
        XCTAssertFalse(ShellWidgetSettingsModel.validClocks([.init(label: "Invalid", zone: "Mars/Olympus")]))
    }

    func testChangingComponentRegionPreservesOtherConfiguredRegionsAndDropsRemovedIDs() {
        let components = [
            ShellComponentInstance(id: "music", widget: "media"),
            ShellComponentInstance(id: "power", widget: "battery")
        ]
        let values: [String: ShellComponentValue] = ["regions": .strings([
            "music:side",
            "power:main",
            "removed:expanded"
        ])]
        XCTAssertEqual(
            ShellWidgetSettingsModel.regions(
                id: "music",
                placement: "expanded",
                components: components,
                values: values
            ),
            .strings(["music:expanded", "power:main"])
        )
        XCTAssertEqual(
            ShellWidgetSettingsModel.regions(id: "music", placement: "auto", components: components, values: values),
            .strings(["power:main"])
        )
    }

    func testColorEditorParsesBothAcceptedRGBAFormatsAndRejectsMalformedValues() {
        XCTAssertEqual(ShellWidgetSettingsModel.rgba("#ff8000"), SIMD4(1, 128.0 / 255, 0, 1))
        XCTAssertEqual(ShellWidgetSettingsModel.rgba("#00000022")?.w, 34.0 / 255)
        XCTAssertNil(ShellWidgetSettingsModel.rgba("black"))
        XCTAssertNil(ShellWidgetSettingsModel.rgba("#12345g"))
    }

    func testBundledOptionMetadataKeepsStyleSpecificDefaultsAndSupportedCapabilities() throws {
        let defaults = try XCTUnwrap(ShellDefaults.bundled)
        let styles = try XCTUnwrap(ShellDefaults.bundledStyles)
        let clock = try XCTUnwrap(ShellRootSettings.load("clock", directories: [defaults]))
        XCTAssertEqual(clock.options["date"]?.defaultValue, .bool(true))
        XCTAssertEqual(clock.options["icon"]?.defaultValue, .bool(false))
        let shell = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: shell) }
        XCTAssertEqual(ShellDefaults.sync(into: shell), [])
        XCTAssertTrue(try ShellProfiles.select("celestial", in: shell))
        var problems: [String] = []
        let config = try XCTUnwrap(ShellConfig.load(shellDirectory: shell, problems: &problems))
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
        let celestial = try ShellServiceValue.decode(XCTUnwrap(config.widgetSettings["clock"])).fields
        XCTAssertEqual(celestial?["date"]?.boolean, false)
        XCTAssertEqual(celestial?["icon"]?.boolean, true)
        let title = try XCTUnwrap(ShellRootSettings.load("active-window", directories: [defaults]))
        XCTAssertEqual(title.options["display"]?.defaultValue, .string("icon_and_text"))
        XCTAssertEqual(title.options["maxWidth"]?.defaultValue, .number(260))
        let celestialTitle = try ShellServiceValue.decode(XCTUnwrap(config.widgetSettings["active-window"])).fields
        XCTAssertEqual(celestialTitle?["maxWidth"]?.number, 320)
        let controlCenter = try XCTUnwrap(ShellRootSettings.load("control-center", directories: [defaults]))
        XCTAssertEqual(controlCenter.options["tab"]?.defaultValue, .string("overview"))
        XCTAssertEqual(
            controlCenter.options["tab"]?.choices,
            ["overview", "audio", "media", "calendar", "weather", "system"]
        )
        let launcher = try XCTUnwrap(ShellRootSettings.load("launcher", directories: [defaults]))
        XCTAssertNil(launcher.options["mode"]?.defaultValue)
        XCTAssertEqual(Set(launcher.options["mode"]?.choices ?? []), Set(CommandPaletteMode.allCases.map(\.rawValue)))
        let status = try XCTUnwrap(ShellRootSettings.load(
            "status", directories: [styles.appendingPathComponent("celestial")]
        ))
        XCTAssertEqual(status.options["network"]?.defaultValue, .bool(true))
        XCTAssertThrowsError(try ShellComponentCatalog.parseOptions(
            .table(["network": .table(["type": .string("boolean")])]), place: "component"
        ))
    }

    func testEveryBundledBarOptionSchemaHasValidDefaults() throws {
        let roots = [try XCTUnwrap(ShellDefaults.bundled)]
            + (try FileManager.default.contentsOfDirectory(
                at: XCTUnwrap(ShellDefaults.bundledStyles),
                includingPropertiesForKeys: nil
            ))
        var checked = 0
        for root in roots {
            for folder in ShellConfig.widgetFolders(in: root) {
                guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("init.luau").path),
                      let schema = try ShellRootSettings.load(folder.lastPathComponent, directories: [root])
                else { continue }
                for option in schema.options.values {
                    if let value = option.defaultValue { XCTAssertTrue(
                        option.accepts(value),
                        "\(root.lastPathComponent)/\(schema.widget)"
                    ) }
                }
                checked += 1
            }
        }
        XCTAssertEqual(checked, 17)
    }
}
