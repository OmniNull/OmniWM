// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class ShellIslandTitlesTests: XCTestCase {
    func testSingleInstanceUsesItsDescriptorTitleWithoutItsDefaultLabel() {
        let titles = titles([component("first")])
        XCTAssertEqual(titles, ["first": "Clock"])
    }

    func testDuplicateDefaultLabelsUseOrdinalsInListOrder() {
        let first = component("first")
        let second = component("second")
        XCTAssertEqual(titles([first, second]), ["first": "Clock · Local 1", "second": "Clock · Local 2"])
        XCTAssertEqual(titles([second, first]), ["first": "Clock · Local 2", "second": "Clock · Local 1"])
    }

    func testDistinctLabelsAreTrimmedAndTakePrecedenceOverOrdinals() {
        let first = component("first", label: "  Toronto  ")
        let second = component("second", label: "London")
        XCTAssertEqual(titles([first, second]), ["first": "Clock · Toronto", "second": "Clock · London"])
    }

    func testEmptyLabelsUseOrdinalsAmongAllInstancesWithTheSameTitle() {
        let first = component("first", label: "Local")
        let second = component("second", label: " \n ")
        XCTAssertEqual(titles([first, second]), ["first": "Clock · Local", "second": "Clock 2"])
        XCTAssertEqual(titles([second, first]), ["first": "Clock · Local", "second": "Clock 1"])
        XCTAssertEqual(
            titles([component("first", label: ""), component("second", label: " ")]),
            ["first": "Clock 1", "second": "Clock 2"]
        )
    }

    func testDescriptorWithoutAStringLabelUsesOrdinalsAndNeverInstanceIDs() {
        let descriptors = ["clock": descriptor(label: .init(kind: .boolean, title: "Label", defaultValue: .bool(true)))]
        let values = ShellIslandTitles.titles(
            components: [component("private-a"), component("private-b")],
            descriptors: descriptors
        )
        XCTAssertEqual(values, ["private-a": "Clock 1", "private-b": "Clock 2"])
        XCTAssertFalse(values.values.contains { $0.contains("private-") })
    }

    func testMissingDescriptorFallsBackToTheWidgetTitle() {
        XCTAssertEqual(
            ShellIslandTitles.titles(
                components: [.init(id: "private-instance", widget: "world-clock")],
                descriptors: [:]
            ),
            ["private-instance": ShellBarLayout.title(of: "world-clock")]
        )
    }

    func testTheStyleStringsTranslateDescriptorTitlesBeforeOrdinalsAreAdded() {
        let descriptor = descriptor()
        let translated = "Uhr"
        let strings = ShellStrings([descriptor.title: translated])
        XCTAssertEqual(
            ShellIslandTitles.titles(
                components: [component("first", label: ""), component("second", label: "")],
                descriptors: [descriptor.widget: descriptor], strings: strings
            ),
            ["first": "\(translated) 1", "second": "\(translated) 2"]
        )
    }

    private func component(_ id: String, label: String? = nil) -> ShellComponentInstance {
        .init(id: id, widget: "clock", options: label.map { ["label": .string($0)] } ?? [:])
    }

    private func titles(_ components: [ShellComponentInstance]) -> [String: String] {
        ShellIslandTitles.titles(components: components, descriptors: ["clock": descriptor()])
    }

    private func descriptor(label: ShellComponentOption? = nil) -> ShellComponentDescriptor {
        .init(
            widget: "clock", title: "Clock", icon: "clock", views: ["compact"], uses: [],
            options: ["label": label ?? .init(kind: .string, title: "Label", defaultValue: .string("Local"))],
            capabilities: .init(), providerCommand: nil, folder: URL(fileURLWithPath: "/unused/clock")
        )
    }
}
