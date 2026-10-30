// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMScriptHost
import XCTest

extension ShellBundledWidgetTests {
    func testNocturneScratchpadOptionControlsIconsAndOverflowAtBothOrientations() throws {
        let directory = try nocturneShellDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let references = (0 ..< 8).map { "ow_option_\($0)" }
        for vertical in [false, true] {
            for shown: Int? in [nil, 0, 1, 6] {
                var data = try fullData(vertical: vertical) { bar in
                    bar.scratchpads = [ShellBarScratchpad(
                        id: 1, name: "Notes", focused: true, revealed: true, visible: true,
                        windows: references.map {
                            ShellBarItem(
                                id: $0,
                                bundle: "com.apple.finder",
                                name: $0,
                                focused: false,
                                count: 1,
                                hidden: 0,
                                windows: []
                            )
                        }
                    )]
                }
                if let settings = try resolvedSettings(
                    widget: "scratchpads", key: "shownWindows", value: shown, directory: directory
                ) { data.append(("settings", settings)) }
                let expected = shown ?? 2
                try renderStyle("nocturne", widget: "scratchpads", data: data, capture: { view, bytes, text in
                    guard view == OMNI_VIEW_BAR else { return }
                    try self.writeAppearanceSnapshots(
                        bytes, text: text,
                        name: "nocturne-scratchpads-\(vertical ? "vertical" : "horizontal")-\(expected)"
                    )
                }, inspect: { view, nodes, text in
                    guard view == OMNI_VIEW_BAR else { return }
                    let icons = nodes.filter { UInt32($0.flags) & OMNI_NODE_ICON_MASK == OMNI_NODE_ICON_WINDOW }
                    XCTAssertEqual(icons.map { text.string($0.icon_ref) }, Array(references.prefix(expected)))
                    XCTAssertEqual(
                        nodes.map { text.string($0.text) }.filter { $0.hasPrefix("+") },
                        ["+\(8 - expected)"]
                    )
                    let target = try XCTUnwrap(nodes.first { text.string($0.target) == "scratchpad 1" })
                    XCTAssertEqual(text.string(target.action), "scratchpad toggle 1")
                })
            }
        }
    }

    func testNocturneCalendarOptionLimitsUpcomingEventsAfterFilteringExpiredOnes() throws {
        let directory = try nocturneShellDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let titles = (0 ..< 14).map { "Upcoming event \($0)" }
        let events = (["Expired event"] + titles).enumerated().map { index, title in
            ShellCalendarEvent(
                id: "event-\(index)", title: title, calendar: "Work", color: "#FF9500",
                start: index == 0 ? 999_000 : 1_001_000 + Double(index * 60),
                end: index == 0 ? 1_000_000 : 1_001_060 + Double(index * 60),
                allDay: false, location: nil, time: "9:30", day: "Today"
            )
        }
        let calendar = ShellCalendar(access: "full", events: events, month: ShellCalendarMonth(
            title: "October 2026", year: 2026, month: 10, days: 31, offset: 4, today: 8,
            weekdays: ["S", "M", "T", "W", "T", "F", "S"], marked: [8]
        ))
        for limit: Int? in [nil, 1, 4, 12] {
            var inspectedPopout = false
            var data = try fullData().filter { $0.0 != "calendar" }
            data.append(("calendar", value { calendar.write(into: &$0) }))
            if let settings = try resolvedSettings(
                widget: "calendar", key: "agendaEvents", value: limit, directory: directory
            ) { data.append(("settings", settings)) }
            try renderStyle("nocturne", widget: "calendar", data: data, capture: { view, bytes, text in
                guard view == OMNI_VIEW_POPOUT else { return }
                try self.writeAppearanceSnapshots(bytes, text: text, name: "nocturne-calendar-\(limit ?? 6)")
            }, inspect: { view, nodes, text in
                guard view == OMNI_VIEW_POPOUT else { return }
                inspectedPopout = true
                let strings = nodes.map { text.string($0.text) }
                XCTAssertEqual(strings.filter { $0.hasPrefix("Upcoming event ") }, Array(titles.prefix(limit ?? 6)))
                XCTAssertFalse(strings.contains("Expired event"))
            })
            XCTAssertTrue(inspectedPopout, "Calendar must render a popout")
        }
    }

    func testNocturneWeatherOptionControlsForecastHoursAndColumnWidths() throws {
        let directory = try nocturneShellDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var stripWidth: Float?
        for hours: Int? in [nil, 4, 8, 12] {
            var data = try fullData()
            if let settings = try resolvedSettings(
                widget: "weather", key: "forecastHours", value: hours, directory: directory
            ) { data.append(("settings", settings)) }
            let expected = hours ?? 12
            var forecastWidth: Float = 0
            var inspectedPopout = false
            try renderStyle("nocturne", widget: "weather", data: data, capture: { view, bytes, text in
                guard view == OMNI_VIEW_POPOUT else { return }
                let layout = ShellWidgetLayout()
                XCTAssertTrue(layout.apply(bytes, text: text))
                XCTAssertLessThanOrEqual(forecastWidth, Float(layout.size.width))
                try self.writeAppearanceSnapshots(bytes, text: text, name: "nocturne-weather-\(expected)")
            }, inspect: { view, nodes, text in
                guard view == OMNI_VIEW_POPOUT else { return }
                inspectedPopout = true
                let indices = nodes.indices.filter { Int(text.string(nodes[$0].text)) != nil }
                XCTAssertEqual(indices.map { text.string(nodes[$0].text) }, (0 ..< expected).map(String.init))
                let widths = try indices.map { index in
                    try XCTUnwrap(nodes[..<index].last { Int($0.subtree_end) > index }).width
                }
                XCTAssertEqual(Set(widths).count, 1)
                XCTAssertGreaterThan(try XCTUnwrap(widths.first), 0)
                let total = widths.reduce(0, +)
                forecastWidth = total
                if let stripWidth { XCTAssertEqual(total, stripWidth, accuracy: 12) }
                else { stripWidth = total }
            })
            XCTAssertTrue(inspectedPopout, "Weather must render a popout")
        }
    }

    private func nocturneShellDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertEqual(try ShellStyleFixture.prepare(into: directory), [])
        XCTAssertTrue(try ShellProfiles.select("nocturne", in: directory))
        return directory
    }

    private func resolvedSettings(
        widget: String, key: String, value: Int?, directory: URL
    ) throws -> [UInt8]? {
        _ = try ShellProfiles.setValue(
            value, at: ShellProfiles.key("widgets", of: "nocturne") + [widget, key], in: directory
        )
        var problems: [String] = []
        let config = try XCTUnwrap(ShellConfig.load(shellDirectory: directory, problems: &problems))
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
        return config.widgetSettings[widget]
    }
}
