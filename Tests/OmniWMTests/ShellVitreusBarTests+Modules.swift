// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

private let unit = 1.35

private func sine(_ degrees: Double) -> Double {
    sin(degrees * .pi / 180)
}

private func expect(_ numbers: [Double], _ values: [Double], _ label: String) {
    XCTAssertEqual(numbers.count, values.count, label)
    for (value, target) in zip(numbers, values) {
        XCTAssertEqual(value, target, accuracy: 0.0011, label)
    }
}

@MainActor
extension ShellVitreusBarTests {
    func testEveryStubModuleLoadsWithItsHooksAndDrawsNothing() throws {
        let names = Self.stubs.map { "\"\($0.0)\"" }.joined(separator: ", ")
        let lines = try probe("""
        function render(ctx)
            local rows = {}
            for _, name in { \(names) } do
                local module = require("../lib/vitreus/" .. name)
                local keys = {}
                for key, value in module do
                    keys[#keys + 1] = key
                    if type(value) == "function" and key ~= "width" and value(ctx, {}) ~= nil then
                        keys[#keys + 1] = "drew"
                    end
                end
                table.sort(keys)
                rows[#rows + 1] = name .. ":" .. table.concat(keys, ",")
            end
            return ui.text{ text = table.concat(rows, ";") }
        end
        """)
        let rows = try XCTUnwrap(lines.first).split(separator: ";").map(String.init)
        XCTAssertEqual(rows, Self.stubs.map { "\($0.0):" + $0.1.joined(separator: ",") })
        let widths = try probe("""
        local units = require("../lib/vitreus/units")
        function render(ctx)
            local k = units.of({ size = { w = 1920, h = 1080 } }, 1)
            local rows = {}
            for _, name in { "search", "omniwm", "controls" } do
                rows[#rows + 1] = table.concat({ require("../lib/vitreus/bar/buttons").width(ctx, k, name) }, " ")
            end
            for _, name in { "marks", "tray", "clock" } do
                rows[#rows + 1] = table.concat({ require("../lib/vitreus/bar/" .. name).width(ctx, k, name) }, " ")
            end
            return ui.text{ text = table.concat(rows, ";") }
        end
        """)
        let measured = try XCTUnwrap(widths.first).split(separator: ";").flatMap { Self.numbers(String($0)) }
        expect(measured, [16.2, 0, 20.25, 0, 17.55, 0, 172.8, 0, 0, 0, 0, 0, 0], "piece widths")
    }

    func testPencilIconsKeepTheVitreusStrokesAndJitterInDegrees() throws {
        let lines = try probe("""
        local pencil = require("../lib/vitreus/pencil")
        function render(ctx)
            local rows = {}
            for _, spec in { { "search", 0, 0 }, { "controls", 1, 3 } } do
                local passes = pencil.icon(spec[1], 100, 50, 1.35, spec[2], spec[3])
                local parts = { spec[1], #passes }
                for _, pass in passes do
                    parts[#parts + 1] = (pass.width or 0) .. "/" .. pass.alpha
                end
                rows[#rows + 1] = table.concat(parts, " ")
            end
            local search = pencil.icon("search", 100, 50, 1.35, 1, 3)
            local over = pencil.icon("overview", 10, 10, 24.3, 0, 0, 1.35, 2)
            return ui.column{
                ui.text{ text = table.concat(rows, ";") }, ui.text{ text = search[1].d }, ui.text{ text = search[4].d },
                ui.text{ text = over[4].d .. "|" .. over[4].width .. "|" .. over[4].tone },
                ui.stack{ w = 200, h = 100, table.unpack(pencil.draw(200, 100, search, "foreground", 0.65)) },
            }
        end
        """)
        let heads = lines[0].split(separator: ";").map { $0.split(separator: " ").prefix(4).joined(separator: " ") }
        XCTAssertEqual(heads, [(1.7, "search 4"), (1.6, "controls 8")].map {
            "\($0.1) \($0.0 * unit)/1 \($0.0 * unit * 0.7)/0.34"
        })
        let jitter = 0.4 * unit
        let radius = 4 * unit * (1 + 0.04 * sine(3 * 47 + 13020))
        let ring = (
            x: 100 - 1.2 * unit + jitter * sine(3 * 51 + 22357), y: 50 - 1.2 * unit + jitter * sine(3 * 63 + 22514)
        )
        expect(Self.numbers(lines[1]), [
            ring.x, ring.y - radius, radius, radius, 0, 1, 1, ring.x, ring.y + radius, radius, radius, 0, 1, 1,
            ring.x, ring.y - radius
        ], "ring")
        expect(Self.numbers(lines[2]), [
            100 + 0.5 * unit + 1.8 * unit + jitter * sine(3 * 70 + 22684),
            50 + 0.4 * unit + 1.8 * unit + jitter * sine(3 * 44 + 22744),
            100 + 0.5 * unit + 5 * unit + jitter * sine(3 * 46 + 22781),
            50 + 0.4 * unit + 5 * unit + jitter * sine(3 * 51 + 22841)
        ], "faint handle")
        let over = lines[3].split(separator: "|").map(String.init)
        let rest = 0.1 * unit
        let (dx, dy) = (10 + 0.4 * unit, 10 + 0.3 * unit)
        expect(Self.numbers(over[0]), [
            dx - 0.25 * 24.3 + rest * sine(23744), dy - 0.15 * 24.3 + rest * sine(23804),
            dx + 0.41 * 24.3 + rest * sine(23841), dy - 0.15 * 24.3 + rest * sine(23901),
            dx + 0.41 * 24.3 + rest * sine(23938), dy + 0.35 * 24.3 + rest * sine(23998),
            dx - 0.25 * 24.3 + rest * sine(24035), dy + 0.35 * 24.3 + rest * sine(24095)
        ], "faint overview window")
        XCTAssertEqual(Array(over.dropFirst()), ["1.4", "2"])
    }

    func testPencilOutlinesAndLinesBowThroughTheirViaPoints() throws {
        let lines = try probe("""
        local pencil = require("../lib/vitreus/pencil")
        function render(ctx)
            local outline = pencil.outline(40, 20, 20, 16, 1.35, 1, 2)
            local line = pencil.line(40, 20, 30, 1.35, 0, 0)
            return ui.column{
                ui.text{ text = outline[1].d }, ui.text{ text = outline[2].d }, ui.text{ text = line[1].d },
                ui.text{ text = outline[1].width .. " " .. outline[2].width .. " " .. outline[2].alpha },
            }
        end
        """)
        let (edge, via) = (0.55 * unit, 1.35 * unit)
        let corner = 0.3 * 16.0
        let drawn = Self.numbers(lines[0])
        expect(Array(drawn.prefix(6)), [
            30 + corner + edge * sine(2 * 55 + 37100), 12 + edge * sine(2 * 60 + 37160),
            40 + via * sine(2 * 55 + 40107), 12 + via * sine(2 * 60 + 40167),
            50 - corner + edge * sine(2 * 62 + 37197), 12 + edge * sine(2 * 67 + 37257)
        ], "outline start")
        expect(Array(drawn.suffix(4)), [
            30 + via * sine(2 * 73 + 40786), 12 + via * sine(2 * 78 + 40846),
            30 + corner + edge * sine(2 * 49 + 37876), 12 + edge * sine(2 * 54 + 37936)
        ], "outline close")
        expect(Array(Self.numbers(lines[1]).prefix(2)), [
            30 + corner + 0.35 * unit + edge * sine(2 * 61 + 37577),
            12 + 0.3 * unit + edge * sine(2 * 66 + 37637)
        ], "faint outline")
        let (rest, bow) = (0.15 * unit, 0.5 * unit)
        expect(Self.numbers(lines[2]), [
            25 + rest * sine(42400), 20 + rest * sine(42460),
            32.5 + bow * sine(45407), 20 - 0.8 * unit + bow * sine(45467),
            40 + rest * sine(42497), 20 + rest * sine(42557),
            47.5 + bow * sine(45504), 20 + 0.8 * unit + bow * sine(45564),
            55 + rest * sine(42594), 20 + rest * sine(42654)
        ], "underline")
        expect(Self.numbers(lines[3]), [1.3 * unit, 0.9 * unit, 0.4], "outline passes")
    }
}
