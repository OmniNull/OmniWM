// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import QuartzCore
import XCTest

extension ShellGlassProbeTests {
    private static let gradientEnds = [
        CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1),
        CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
    ]

    private static func lineDeviation(_ colors: [[Int]]) -> Int {
        guard let first = colors.first, let last = colors.last, colors.count > 1 else { return .max }
        var worst = 0
        for (index, color) in colors.enumerated() {
            let fraction = Double(index) / Double(colors.count - 1)
            for channel in 0 ..< 3 {
                let expected = Double(first[channel]) + Double(last[channel] - first[channel]) * fraction
                worst = max(worst, Int(abs(Double(color[channel]) - expected).rounded()))
            }
        }
        return worst
    }

    private static func endsMatchDeclared(_ colors: [[Int]]) -> Bool {
        let declared = [[255, 0, 0], [0, 0, 255]]
        guard let first = colors.first, let last = colors.last, first != last else { return false }
        return [first, last]
            .allSatisfy { color in declared.contains { zip($0, color).allSatisfy { abs($0 - $1) <= 3 } } }
    }

    private static func profile(_ colors: [[Int]]) -> [String: Any] {
        [
            "quarters": (0 ... 4).map { colors[($0 * (colors.count - 1)) / 4] },
            "maxDeviationFromEndToEndLine": lineDeviation(colors),
            "endsMatchDeclared": endsMatchDeclared(colors)
        ]
    }

    private func gradientPixels(_ name: String, _ values: [String: Any]) throws -> GlassProbePixels {
        let effect = try XCTUnwrap((NSClassFromString(name) as? NSObject.Type)?.init())
        for (key, value) in values {
            effect.setValue(value, forKey: key)
        }
        let shape = try element(CGRect(x: 20, y: 20, width: 160, height: 60))
        return try sdfCanvas(effect, size: CGSize(width: 200, height: 100), elements: [shape]).canvas.render()
    }

    private func contourProbe() throws -> (cases: [String: Any], linear: Bool) {
        var cases: [String: Any] = [:]
        var linear = false
        for angle in [0.0, Double.pi / 2] {
            for radius in [10.0, 30, 80] {
                let pixels = try gradientPixels("CASDFGradientContourEffect", [
                    "startColor": Self.gradientEnds[0], "endColor": Self.gradientEnds[1], "angle": angle,
                    "radius": radius
                ])
                let lines = [(23 ... 176).map { pixels.rgb($0, 50) }, (23 ... 76).map { pixels.rgb(100, $0) }]
                let matched = lines.contains { Self.endsMatchDeclared($0) && Self.lineDeviation($0) <= 3 }
                linear = linear || matched
                cases["angle \(Self.rounded(angle)) radius \(Int(radius))"] = [
                    "row50": Self.profile(lines[0]), "column100": Self.profile(lines[1]), "linearWithin3": matched
                ]
            }
        }
        return (cases, linear)
    }

    private func distanceGradientProbe() throws -> (cases: [String: Any], linear: Bool) {
        var cases: [String: Any] = [:]
        var linear = false
        let depths = [1, 5, 10, 15, 20, 30, 40]
        for distances in [[0.0, 20], [-20.0, 0]] {
            let pixels = try gradientPixels(
                "CASDFGradientEffect",
                ["colors": Self.gradientEnds, "distances": distances]
            )
            let ramp = (21 ... 39).map { pixels.rgb($0, 50) }
            let matched = ramp.first != ramp.last && Self.lineDeviation(ramp) <= 3
            linear = linear || matched
            cases["distances \(distances.map { Int($0) })"] = [
                "colorsByDepthFromLeftEdge": Dictionary(uniqueKeysWithValues: depths.map { (
                    "\($0)",
                    pixels.rgb(20 + $0, 50)
                ) }),
                "firstTwentyPoints": Self.profile(ramp),
                "linearInDistanceWithin3": matched
            ]
        }
        return (cases, linear)
    }

    func testGradientEffectsOnFlatRectProbe() throws {
        let probe = "d.gradientEffects"
        try requireNative(probe, classes: ["CASDFGradientContourEffect", "CASDFGradientEffect"])
        let contour = try contourProbe()
        let distance = try distanceGradientProbe()
        try record(probe, [
            "outcome": [
                "gradientContourEffect": contour.linear ? "linear gradient within 3" : "no linear gradient within 3",
                "gradientEffect": distance.linear ? "linear in signed distance from the edge, not across the rect"
                    : "no linear ramp within 3"
            ],
            "setup": "160x60 rect, start red, end blue; contour sampled along row 50 and column 100, 3 pt inside",
            "gradientContourEffect": contour.cases,
            "gradientEffect": distance.cases
        ])
    }

    private static let unionShapes = [
        ShellGlassShape(slot: 1, kind: 0, rect: CGRect(x: 16, y: 16, width: 70, height: 50), radius: 12, thickness: 0),
        ShellGlassShape(slot: 2, kind: 0, rect: CGRect(x: 66, y: 40, width: 76, height: 44), radius: 12, thickness: 0),
        ShellGlassShape(slot: 3, kind: 1, rect: CGRect(x: 34, y: 78, width: 64, height: 26), radius: 0, thickness: 0)
    ]

    private func unionGlass(_ order: [Int]) throws -> GlassProbePixels {
        let canvas = try GlassProbeCanvas(width: 160, height: 120)
        canvas.add(try body(order.map { Self.unionShapes[$0] }, size: CGSize(width: 160, height: 120)).layer)
        return try canvas.render()
    }

    private func unionFill(_ order: [Int]) throws -> GlassProbePixels {
        let parts = try order.map { index in
            let shape = Self.unionShapes[index]
            guard shape.kind == 1 else { return try element(shape.rect, radius: shape.radius) }
            let radius = min(shape.rect.width, shape.rect.height) / 2
            let scale = CATransform3DMakeScale(shape.rect.width / (2 * radius), shape.rect.height / (2 * radius), 1)
            let circle = CGRect(origin: shape.rect.origin, size: CGSize(width: 2 * radius, height: 2 * radius))
            return try element(circle, radius: radius, transform: scale)
        }
        let size = CGSize(width: 160, height: 120)
        return try sdfCanvas(fill(), size: size, smoothness: 52, elements: parts).canvas.render()
    }

    private static func orderDifferences(_ render: ([Int]) throws -> GlassProbePixels) throws
        -> (cases: [String: Any], worst: Int)
    {
        let reference = try render([0, 1, 2])
        let pair = try render([0, 1])
        var cases: [String: Any] = [:]
        var worst = 0
        for order in [[2, 1, 0], [1, 2, 0], [0, 2, 1], [1, 0]] {
            let difference = try render(order).difference(order.count == 2 ? pair : reference)
            worst = max(worst, difference.max)
            cases["\(order)"] = ["changedBytes": difference.changed, "maxCodeValueDelta": difference.max]
        }
        return (cases, worst)
    }

    func testUnionOrderProbe() throws {
        let probe = "e.unionOrder"
        try requireNative(probe)
        let glass = try Self.orderDifferences(unionGlass)
        let fillOnly = try Self.orderDifferences(unionFill)
        try record(probe, [
            "outcome": max(glass.worst, fillOnly.worst) <= 2 ? "order independent within 2 code values" :
                "order dependent",
            "setup": "two rounded rects and an ellipse at smoothness 52 (blend 26); three-shape orders against "
                + "[0, 1, 2] and the two-shape swap against [0, 1]",
            "glassBody": glass.cases,
            "fillOnlySDF": fillOnly.cases
        ])
    }

    private static let ellipseBox = CGRect(x: 90, y: 30, width: 120, height: 40)

    private func ellipsePixels(_ ellipse: Bool, neighbour: CGRect?, smoothness: CGFloat) throws -> GlassProbePixels {
        let box = Self.ellipseBox
        let circle = CGRect(origin: box.origin, size: CGSize(width: 40, height: 40))
        let shape = try ellipse
            ? element(circle, radius: 20, transform: CATransform3DMakeScale(3, 1, 1))
            : element(box, radius: 20)
        let parts = try [shape] + (neighbour.map { [try element($0)] } ?? [])
        let size = CGSize(width: 300, height: 110)
        return try sdfCanvas(fill(), size: size, smoothness: smoothness, elements: parts).canvas.render()
    }

    private func outlineError(_ ellipse: Bool) throws -> Double {
        let pixels = try ellipsePixels(ellipse, neighbour: nil, smoothness: 0)
        let center = CGPoint(x: Self.ellipseBox.midX, y: Self.ellipseBox.midY)
        var worst = 0.0
        for y in 35 ... 64 {
            let dy = Double(y) + 0.5 - center.y
            let half = ellipse ? 60 * (1 - dy * dy / 400).squareRoot() : 40 + (400 - dy * dy).squareRoot()
            guard let span = pixels.span(row: y) else { return -1 }
            worst = max(worst, abs(span.min - (center.x - half)), abs(span.max - (center.x + half)))
        }
        return Self.rounded(worst)
    }

    private func fillet(
        _ ellipse: Bool,
        neighbour: CGRect,
        line: (GlassProbePixels) -> (min: Double, max: Double)?
    ) throws -> Double {
        let smooth = line(try ellipsePixels(ellipse, neighbour: neighbour, smoothness: 40))
        let hard = line(try ellipsePixels(ellipse, neighbour: neighbour, smoothness: 0))
        return Self.rounded((smooth.map { $0.max - $0.min } ?? 0) - (hard.map { $0.max - $0.min } ?? 0))
    }

    private func ellipseSummary(_ ellipse: Bool) throws -> [String: Double] {
        try [
            "xAxisFilletAlongBarBelow": fillet(ellipse, neighbour: CGRect(x: 0, y: 70, width: 300, height: 40)) {
                $0.span(row: 69)
            },
            "yAxisFilletAlongBarBeside": fillet(ellipse, neighbour: CGRect(x: 0, y: 0, width: 90, height: 110)) {
                $0.span(column: 91)
            },
            "outlineMaxErrorPt": outlineError(ellipse)
        ]
    }

    func testEllipseAgainstStadiumProbe() throws {
        let probe = "f.ellipseVersusStadium"
        try requireNative(probe)
        let ellipse = try ellipseSummary(true)
        let stadium = try ellipseSummary(false)
        let ratio = { (key: String) in Self.rounded((ellipse[key] ?? 0) / max(stadium[key] ?? 0, 0.001)) }
        try record(probe, [
            "outcome": "ellipse fillet is \(ratio("xAxisFilletAlongBarBelow"))x the stadium's on the x axis and "
                + "\(ratio("yAxisFilletAlongBarBeside"))x on the y axis",
            "setup": "120x40 box: circle r=20 scaled (3, 1) versus a radius 20 stadium; smoothness 40 against a flat "
                + "neighbour touching the bottom edge (x axis fillet) or the left tip (y axis fillet)",
            "ellipse": ellipse,
            "stadium": stadium,
            "pleamarEllipseReference": "(|p/e|-r)*min(e)"
        ])
    }

    func testBodyWithoutBackdropProbe() throws {
        let probe = "g.bodyWithoutBackdrop"
        try requireNative(probe)
        let backdropClass = try XCTUnwrap(capability.backdropClass)
        let canvas = try GlassProbeCanvas(width: 96, height: 96, background: CGColor(gray: 0.5, alpha: 1))
        let rect = CGRect(x: 16, y: 16, width: 64, height: 64)
        let glass = try body(
            [ShellGlassShape(slot: 1, kind: 0, rect: rect, radius: 12, thickness: 0)],
            size: CGSize(width: 96, height: 96)
        )
        let backdrops = glass.layer.sublayers?.filter { $0.isKind(of: backdropClass) } ?? []
        Self.still { backdrops.forEach { $0.removeFromSuperlayer() } }
        canvas.add(glass.layer)
        let pixels = try canvas.render()
        let interior = pixels.luminance(48, 48)
        let lit = (14 ... 20).map { pixels.luminance($0, 48) }.max() ?? 0
        let unlit = (76 ... 82).map { pixels.luminance($0, 48) }.max() ?? 0
        let tint = pixels.rgb(48, 48)
        try record(probe, [
            "outcome": lit - interior >= 10 ? "lit edge at least 10 brighter" : "lit edge less than 10 brighter",
            "setup": "ShellGlassBody 64x64 radius 12 over 50% gray with its CABackdropLayer removed",
            "backdropLayersRemoved": backdrops.count,
            "interiorLuminance": Self.rounded(interior),
            "litEdgeLuminance": Self.rounded(lit),
            "unlitEdgeLuminance": Self.rounded(unlit),
            "litMinusInterior": Self.rounded(lit - interior),
            "shadowDarkeningBelow": Self.rounded(pixels.luminance(48, 94) - pixels.luminance(48, 82)),
            "interiorRGB": tint,
            "tintVisible": tint[2] > tint[0]
        ])
    }

    private static func checkerboard() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 160, height: 120, bitsPerComponent: 8, bytesPerRow: 0,
            space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 160, height: 120))
        context.setFillColor(CGColor(gray: 0.9, alpha: 1))
        for y in stride(from: 0, to: 120, by: 2) {
            for x in stride(from: 0, to: 160, by: 2) where (x / 2 + y / 2).isMultiple(of: 2) {
                context.fill(CGRect(x: x, y: y, width: 2, height: 2))
            }
        }
        return try XCTUnwrap(context.makeImage())
    }

    private func framePixels(
        band: CGFloat?,
        checker: CGImage
    ) throws -> (pixels: GlassProbePixels, body: ShellGlassBody?) {
        let canvas = try GlassProbeCanvas(width: 160, height: 120, contents: checker)
        guard let band else { return (try canvas.render(), nil) }
        let frame = ShellGlassShape(
            slot: 1, kind: 2, rect: CGRect(x: -80, y: -80, width: 320, height: 280),
            radius: 100 + band, thickness: 80 + band
        )
        let glass = try body([frame], size: CGSize(width: 160, height: 120))
        canvas.add(glass.layer)
        return (try canvas.render(), glass)
    }

    private static func edgeContrast(_ pixels: GlassProbePixels) -> Double {
        var total = 0.0
        for y in 30 ..< 90 {
            for x in 0 ..< 5 {
                total += abs(pixels.luminance(x, y) - pixels.luminance(x + 1, y))
            }
        }
        return rounded(total / 300)
    }

    private static func largestDelta(_ pixels: GlassProbePixels, _ raw: GlassProbePixels, columns: Range<Int>) -> Int {
        var largest = 0
        for y in 30 ..< 90 {
            for x in columns {
                largest = max(largest, zip(pixels.rgb(x, y), raw.rgb(x, y)).map { abs($0 - $1) }.max() ?? 0)
            }
        }
        return largest
    }

    func testThinFrameBackdropCoverageProbe() throws {
        let probe = "k.thinFrame"
        try requireNative(probe)
        let checker = try Self.checkerboard()
        let raw = try framePixels(band: nil, checker: checker).pixels
        var bands: [String: Any] = [:]
        var interiorClear = false
        for band: CGFloat in [0.5, 12] {
            let rendered = try framePixels(band: band, checker: checker)
            let glass = try XCTUnwrap(rendered.body)
            let interior = Self.largestDelta(rendered.pixels, raw, columns: 30 ..< 130)
            if band < 1 { interiorClear = interior <= 2 }
            bands["\(band)"] = [
                "nativeAvailable": glass.nativeAvailable,
                "failure": glass.failure ?? "",
                "coverageMaskParts": glass.maskElements.count,
                "interiorMaxDeltaVsBackground": interior,
                "edgeContrast": Self.edgeContrast(rendered.pixels),
                "edgeColumnMaxDeltaVsBackground": Self.largestDelta(rendered.pixels, raw, columns: 0 ..< 1)
            ]
        }
        try record(probe, [
            "outcome": interiorClear ? "thin frame leaves the interior unfrosted" : "thin frame frosts the interior",
            "setup": "frame shape 80 pt outside a 160x120 canvas with a visible band of 0.5 or 12 pt over a 2 pt "
                + "checkerboard; edge contrast = mean luminance step over columns 0-5",
            "backgroundEdgeContrast": Self.edgeContrast(raw),
            "bands": bands
        ])
    }
}
