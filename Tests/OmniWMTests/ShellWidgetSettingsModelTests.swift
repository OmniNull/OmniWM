// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class ShellWidgetSettingsModelTests: XCTestCase {
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
        let celestial = try XCTUnwrap(ShellRootSettings.load(
            "clock",
            directories: [styles.appendingPathComponent("celestial")]
        ))
        XCTAssertEqual(clock.options["date"]?.defaultValue, .bool(true))
        XCTAssertEqual(celestial.options["date"]?.defaultValue, .bool(false))
        XCTAssertNil(clock.options["icon"])
        XCTAssertEqual(celestial.options["icon"]?.defaultValue, .bool(true))
        let title = try XCTUnwrap(ShellRootSettings.load(
            "active-window",
            directories: [styles.appendingPathComponent("celestial")]
        ))
        XCTAssertNil(title.options["display"])
        XCTAssertEqual(title.options["maxWidth"]?.defaultValue, .number(320))
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
        XCTAssertGreaterThan(checked, 30)
    }
}
