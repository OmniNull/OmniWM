// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

struct ShellPathData: Equatable, Sendable {
    enum Element: Equatable, Sendable {
        case move(CGPoint)
        case line(CGPoint)
        case quad(CGPoint, control: CGPoint)
        case cubic(CGPoint, control1: CGPoint, control2: CGPoint)
        case close
    }

    var elements: [Element] = []
    fileprivate var shape: ShellPathShape?

    func path(fitting viewBox: CGRect?, into size: CGSize) -> CGPath {
        let transform = Self.fittingTransform(viewBox, into: size)
        let path = CGMutablePath()
        for element in elements {
            switch element {
            case let .move(point): path.move(to: point, transform: transform)
            case let .line(point): path.addLine(to: point, transform: transform)
            case let .quad(point, control): path.addQuadCurve(to: point, control: control, transform: transform)
            case let .cubic(point, first, second):
                path.addCurve(to: point, control1: first, control2: second, transform: transform)
            case .close: path.closeSubpath()
            }
        }
        return path.copy() ?? path
    }

    func shape(fitting viewBox: CGRect?, into size: CGSize) -> ShellPathShape? {
        guard let shape else { return nil }
        return shape.fitted(using: Self.fittingTransform(viewBox, into: size))
    }

    private static func fittingTransform(_ viewBox: CGRect?, into size: CGSize) -> CGAffineTransform {
        guard let viewBox, viewBox.width > 0, viewBox.height > 0 else { return .identity }
        return CGAffineTransform(scaleX: size.width / viewBox.width, y: size.height / viewBox.height)
            .translatedBy(x: -viewBox.minX, y: -viewBox.minY)
    }

    fileprivate mutating func move(to point: CGPoint) {
        elements.append(.move(point))
    }

    fileprivate mutating func addLine(to point: CGPoint) {
        elements.append(.line(point))
    }

    fileprivate mutating func addQuadCurve(to point: CGPoint, control: CGPoint) {
        elements.append(.quad(point, control: control))
    }

    fileprivate mutating func addCurve(to point: CGPoint, control1: CGPoint, control2: CGPoint) {
        elements.append(.cubic(point, control1: control1, control2: control2))
    }

    fileprivate mutating func closeSubpath() {
        elements.append(.close)
    }
}

enum ShellPath {
    static let maximumCommands = 4096

    static func parse(_ source: String) -> ShellPathData? {
        var parser = Parser(reader: Reader(bytes: Array(source.utf8)))
        var command: UInt8 = 0
        var steps = 0
        while parser.reader.skipSeparators() {
            if let letter = parser.reader.command() {
                command = letter
            } else if command == 0 || command == UInt8(ascii: "z") || command == UInt8(ascii: "Z") {
                return nil
            }
            steps += 1
            guard steps <= maximumCommands, parser.apply(command) else { return nil }
            if command == UInt8(ascii: "m") {
                command = UInt8(ascii: "l")
            } else if command == UInt8(ascii: "M") {
                command = UInt8(ascii: "L")
            }
        }
        let closes = command | 0x20 == UInt8(ascii: "z")
        if steps == ShellPathBand.commandCount, closes, parser.arcCount == parser.bandEdges.count,
           case .move? = parser.path.elements.first
        {
            parser.path.shape = ShellPathBand(parser.bandEdges).map { .band($0) }
        } else if steps != 2 {
            parser.path.shape = nil
        }
        return parser.path.elements.isEmpty ? nil : parser.path
    }

    static func haveMatchingSegments(_ first: CGPath, _ second: CGPath) -> Bool {
        func segmentTypes(_ path: CGPath) -> [CGPathElementType] {
            var types: [CGPathElementType] = []
            path.applyWithBlock { types.append($0.pointee.type) }
            return types
        }
        return segmentTypes(first) == segmentTypes(second)
    }

    private struct Parser {
        var reader: Reader
        var path = ShellPathData()
        var current = CGPoint.zero
        var start = CGPoint.zero
        var cubic: CGPoint?
        var quadratic: CGPoint?
        var bandEdges = InlineArray<4, ShellPathBand.Edge?>(repeating: nil)
        var arcCount = 0

        mutating func apply(_ command: UInt8) -> Bool {
            let relative = command >= UInt8(ascii: "a")
            let origin = relative ? current : .zero
            let previousCubic = cubic
            let previousQuadratic = quadratic
            cubic = nil
            quadratic = nil
            switch command | 0x20 {
            case UInt8(ascii: "m"),
                 UInt8(ascii: "l"),
                 UInt8(ascii: "h"),
                 UInt8(ascii: "v"),
                 UInt8(ascii: "z"):
                return line(command | 0x20, origin: origin, relative: relative)
            case UInt8(ascii: "c"):
                return cubicCurve(origin: origin, first: nil)
            case UInt8(ascii: "s"):
                return cubicCurve(origin: origin, first: previousCubic.map { current + (current - $0) } ?? current)
            case UInt8(ascii: "q"):
                return quadCurve(origin: origin, control: nil)
            case UInt8(ascii: "t"):
                return quadCurve(origin: origin, control: previousQuadratic.map { current + (current - $0) } ?? current)
            case UInt8(ascii: "a"):
                return arc(origin: origin)
            default:
                return false
            }
        }

        private mutating func line(_ command: UInt8, origin: CGPoint, relative: Bool) -> Bool {
            switch command {
            case UInt8(ascii: "m"):
                guard let point = reader.point() else { return false }
                current = origin + point
                start = current
                path.move(to: current)
            case UInt8(ascii: "l"):
                guard let point = reader.point() else { return false }
                current = origin + point
                path.addLine(to: current)
            case UInt8(ascii: "h"):
                guard let x = reader.number() else { return false }
                current.x = (relative ? current.x : 0) + x
                path.addLine(to: current)
            case UInt8(ascii: "v"):
                guard let y = reader.number() else { return false }
                current.y = (relative ? current.y : 0) + y
                path.addLine(to: current)
            default:
                path.closeSubpath()
                current = start
            }
            return true
        }

        private mutating func cubicCurve(origin: CGPoint, first reflected: CGPoint?) -> Bool {
            guard let first = reflected ?? reader.point().map({ origin + $0 }),
                  let second = reader.point(), let point = reader.point()
            else {
                return false
            }
            cubic = origin + second
            current = origin + point
            path.addCurve(to: current, control1: first, control2: origin + second)
            return true
        }

        private mutating func quadCurve(origin: CGPoint, control reflected: CGPoint?) -> Bool {
            guard let control = reflected ?? reader.point().map({ origin + $0 }), let point = reader.point() else {
                return false
            }
            quadratic = control
            current = origin + point
            path.addQuadCurve(to: current, control: control)
            return true
        }

        private mutating func arc(origin: CGPoint) -> Bool {
            guard let rx = reader.number(), let ry = reader.number(), let rotation = reader.number(),
                  let large = reader.flag(), let sweep = reader.flag(), let point = reader.point()
            else {
                return false
            }
            let end = origin + point
            let arc = Arc(radii: CGSize(width: rx, height: ry), rotation: rotation, large: large, sweep: sweep)
            if arcCount < bandEdges.count {
                bandEdges[arcCount] = ShellPathBand.Edge(arc: arc, from: current, to: end)
            }
            arcCount += 1
            ShellPath.addArc(arc, to: &path, from: current, to: end)
            current = end
            return true
        }
    }

    fileprivate struct Arc {
        let radii: CGSize
        let rotation: CGFloat
        let large: Bool
        let sweep: Bool

        var isCircle: Bool {
            radii.width > 0 && radii.width == radii.height
        }
    }

    private static func addArc(_ arc: Arc, to path: inout ShellPathData, from start: CGPoint, to end: CGPoint) {
        guard start != end else { return }
        guard abs(arc.radii.width) > 0, abs(arc.radii.height) > 0 else {
            path.addLine(to: end)
            return
        }
        let geometry = ShellPathArc(arc, from: start, to: end)
        if path.elements.count == 1, case .move = path.elements[0] { path.shape = .arc(geometry) }
        let quarterTurns = abs(geometry.delta) / (.pi / 2)
        let boundaryTolerance = 16 * quarterTurns.ulp
        let segments = max(Int((quarterTurns - boundaryTolerance).rounded(.up)), 1)
        geometry.appendCurves(segments: segments, endingAt: end) { end, first, second in
            path.addCurve(to: end, control1: first, control2: second)
        }
    }

    private struct Reader {
        let bytes: [UInt8]
        var index = 0

        mutating func skipSeparators() -> Bool {
            while index < bytes.count, Self.isSeparator(bytes[index]) {
                index += 1
            }
            return index < bytes.count
        }

        mutating func command() -> UInt8? {
            guard index < bytes.count else { return nil }
            let byte = bytes[index]
            guard Self.isCommand(byte) else { return nil }
            index += 1
            return byte
        }

        mutating func flag() -> Bool? {
            _ = skipSeparators()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "0") || bytes[index] == UInt8(ascii: "1") else {
                return nil
            }
            index += 1
            return bytes[index - 1] == UInt8(ascii: "1")
        }

        mutating func point() -> CGPoint? {
            guard let x = number(), let y = number() else { return nil }
            return CGPoint(x: x, y: y)
        }

        mutating func number() -> CGFloat? {
            _ = skipSeparators()
            let begin = index
            if index < bytes.count, bytes[index] == UInt8(ascii: "-") || bytes[index] == UInt8(ascii: "+") {
                index += 1
            }
            var digits = digitRun()
            if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
                index += 1
                digits += digitRun()
            }
            guard digits > 0 else {
                index = begin
                return nil
            }
            if index < bytes.count, bytes[index] | 0x20 == UInt8(ascii: "e") {
                let mark = index
                index += 1
                if index < bytes.count, bytes[index] == UInt8(ascii: "-") || bytes[index] == UInt8(ascii: "+") {
                    index += 1
                }
                if digitRun() == 0 {
                    index = mark
                }
            }
            guard let text = String(bytes: bytes[begin ..< index], encoding: .ascii),
                  let value = Double(text), value.isFinite, abs(value) <= 1e6
            else {
                return nil
            }
            return CGFloat(value)
        }

        private mutating func digitRun() -> Int {
            let begin = index
            while index < bytes.count, bytes[index] >= UInt8(ascii: "0"), bytes[index] <= UInt8(ascii: "9") {
                index += 1
            }
            return index - begin
        }

        private static func isSeparator(_ byte: UInt8) -> Bool {
            byte == UInt8(ascii: " ") || byte == UInt8(ascii: ",") || byte == 9 || byte == 10 || byte == 13
        }

        private static func isCommand(_ byte: UInt8) -> Bool {
            switch byte | 0x20 {
            case UInt8(ascii: "m"),
                 UInt8(ascii: "l"),
                 UInt8(ascii: "h"),
                 UInt8(ascii: "v"),
                 UInt8(ascii: "c"),
                 UInt8(ascii: "s"),
                 UInt8(ascii: "q"),
                 UInt8(ascii: "t"),
                 UInt8(ascii: "a"),
                 UInt8(ascii: "z"):
                byte >= UInt8(ascii: "A")
            default:
                false
            }
        }
    }
}

private func + (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
    CGPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
}

private func - (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
    CGPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
}

enum ShellPathShape: Equatable, Sendable {
    case arc(ShellPathArc)
    case band(ShellPathBand)

    fileprivate func fitted(using fit: CGAffineTransform) -> Self? {
        switch self {
        case let .arc(arc):
            return .arc(arc.fitted(using: fit))
        case let .band(band):
            guard let fitted = band.fitted(using: fit) else { return nil }
            return .band(fitted)
        }
    }

    func morphs(to target: Self) -> Bool {
        switch (self, target) {
        case (.arc, .arc): true
        case let (.band(band), .band(other)): band.morphs(to: other)
        default: false
        }
    }

    func interpolated(to target: Self, at progress: CGFloat) -> Self {
        switch (self, target) {
        case let (.arc(arc), .arc(other)): .arc(arc.interpolated(to: other, at: progress))
        case let (.band(band), .band(other)): .band(band.interpolated(to: other, at: progress))
        default: target
        }
    }

    func path() -> CGPath {
        switch self {
        case let .arc(arc): arc.path()
        case let .band(band): band.path()
        }
    }
}

struct ShellPathBand: Equatable, Sendable {
    fileprivate struct Edge {
        let arc: ShellPath.Arc
        let from: CGPoint
        let to: CGPoint
    }

    fileprivate static let commandCount = 6
    private static let capSegments = 2
    private static let unseenOffset: CGFloat = 0.25

    private var center: CGPoint
    private var outer: CGFloat
    private var inner: CGFloat
    private var cap: CGFloat
    private var start: CGFloat
    private var sweep: CGFloat
    private var modelOffset: CGFloat = 0
    private var fit = CGAffineTransform.identity

    fileprivate init?(_ edges: InlineArray<4, Edge?>) {
        guard let outerEdge = edges[0], let endCap = edges[1], let innerEdge = edges[2], let startCap = edges[3],
              outerEdge.arc.isCircle, endCap.arc.isCircle, innerEdge.arc.isCircle,
              startCap.arc.radii == endCap.arc.radii, outerEdge.arc.radii.width > innerEdge.arc.radii.width,
              outerEdge.arc.sweep != innerEdge.arc.sweep, outerEdge.arc.large == innerEdge.arc.large,
              endCap.arc.sweep == outerEdge.arc.sweep, startCap.arc.sweep == outerEdge.arc.sweep,
              !endCap.arc.large, !startCap.arc.large, startCap.to == outerEdge.from, outerEdge.from != outerEdge.to
        else { return nil }
        let startAxis = outerEdge.from - innerEdge.to
        let endAxis = outerEdge.to - endCap.to
        let startWidth = hypot(startAxis.x, startAxis.y)
        let endWidth = hypot(endAxis.x, endAxis.y)
        guard startWidth > 0, endWidth > 0 else { return nil }
        outer = outerEdge.arc.radii.width
        inner = innerEdge.arc.radii.width
        cap = endCap.arc.radii.width
        let middle = (outer + inner) / 2
        center = CGPoint(
            x: (outerEdge.from.x + innerEdge.to.x + outerEdge.to.x + endCap.to.x) / 4
                - middle * (startAxis.x / startWidth + endAxis.x / endWidth) / 2,
            y: (outerEdge.from.y + innerEdge.to.y + outerEdge.to.y + endCap.to.y) / 4
                - middle * (startAxis.y / startWidth + endAxis.y / endWidth) / 2
        )
        start = atan2(startAxis.y, startAxis.x)
        let direction: CGFloat = outerEdge.arc.sweep ? 1 : -1
        var turn = (atan2(endAxis.y, endAxis.x) - start) * direction
        turn -= ShellPathArc.fullTurn * (turn / ShellPathArc.fullTurn).rounded(.down)
        var flagOffset: CGFloat = 0
        if outerEdge.arc.large != (turn > .pi) {
            if outerEdge.arc.large, turn < .pi / 2 {
                turn = ShellPathArc.fullTurn
            } else if !outerEdge.arc.large, turn > 3 * .pi / 2 {
                return nil
            } else {
                flagOffset = outer * abs(turn - .pi)
            }
        }
        sweep = turn * direction
        let end = start + sweep
        modelOffset = max(
            flagOffset,
            Self.distance(outerEdge.from, point(outer, start)), Self.distance(outerEdge.to, point(outer, end)),
            Self.distance(endCap.to, point(inner, end)), Self.distance(innerEdge.to, point(inner, start))
        )
    }

    fileprivate func fitted(using fit: CGAffineTransform) -> Self? {
        guard modelOffset * max(abs(fit.a), abs(fit.d)) <= Self.unseenOffset else { return nil }
        var result = self
        result.fit = fit
        return result
    }

    fileprivate func morphs(to target: Self) -> Bool {
        fit == target.fit && sweep * target.sweep > 0
    }

    fileprivate func interpolated(to target: Self, at progress: CGFloat) -> Self {
        func mix(_ from: CGFloat, _ to: CGFloat) -> CGFloat {
            from + (to - from) * progress
        }
        var result = self
        result.center = CGPoint(x: mix(center.x, target.center.x), y: mix(center.y, target.center.y))
        result.outer = mix(outer, target.outer)
        result.inner = mix(inner, target.inner)
        result.cap = mix(cap, target.cap)
        result.start = start + (target.start - start).remainder(dividingBy: ShellPathArc.fullTurn) * progress
        result.sweep = mix(sweep, target.sweep)
        return result
    }

    fileprivate func path() -> CGPath {
        let end = start + sweep
        let capArc = ShellPath.Arc(
            radii: CGSize(width: cap, height: cap), rotation: 0, large: false, sweep: sweep > 0
        )
        let path = CGMutablePath()
        path.move(to: point(outer, start).applying(fit))
        add(
            ShellPathArc(center: center, radius: outer, theta: start, delta: sweep),
            ShellPathArc.fullTurnSegments,
            path
        )
        add(ShellPathArc(capArc, from: point(outer, end), to: point(inner, end)), Self.capSegments, path)
        add(ShellPathArc(center: center, radius: inner, theta: end, delta: -sweep), ShellPathArc.fullTurnSegments, path)
        add(ShellPathArc(capArc, from: point(inner, start), to: point(outer, start)), Self.capSegments, path)
        path.closeSubpath()
        return path
    }

    private func point(_ radius: CGFloat, _ angle: CGFloat) -> CGPoint {
        CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
    }

    private static func distance(_ first: CGPoint, _ second: CGPoint) -> CGFloat {
        hypot(first.x - second.x, first.y - second.y)
    }

    private func add(_ arc: ShellPathArc, _ segments: Int, _ path: CGMutablePath) {
        arc.fitted(using: fit).appendCurves(segments: segments) { end, first, second in
            path.addCurve(to: end, control1: first, control2: second)
        }
    }
}

struct ShellPathArc: Equatable, Sendable {
    fileprivate static let fullTurn = 2 * CGFloat.pi
    fileprivate static let fullTurnSegments = 4

    private var center: CGPoint
    private var radii: CGSize
    private var rotation: CGFloat
    private var fitScale = CGSize(width: 1, height: 1)
    private var theta: CGFloat
    fileprivate private(set) var delta: CGFloat

    private var transform: CGAffineTransform {
        let cosPhi = cos(rotation)
        let sinPhi = sin(rotation)
        return CGAffineTransform(
            a: radii.width * cosPhi * fitScale.width, b: radii.width * sinPhi * fitScale.height,
            c: -radii.height * sinPhi * fitScale.width, d: radii.height * cosPhi * fitScale.height,
            tx: center.x, ty: center.y
        )
    }

    fileprivate init(center: CGPoint, radius: CGFloat, theta: CGFloat, delta: CGFloat) {
        self.center = center
        radii = CGSize(width: radius, height: radius)
        rotation = 0
        self.theta = theta
        self.delta = delta
    }

    fileprivate init(_ arc: ShellPath.Arc, from start: CGPoint, to end: CGPoint) {
        var rx = abs(arc.radii.width)
        var ry = abs(arc.radii.height)
        var rotationDegrees = arc.rotation
        if rx < ry {
            swap(&rx, &ry)
            rotationDegrees += 90
        }
        let phi = rx == ry ? 0 : rotationDegrees.remainder(dividingBy: 180) * .pi / 180
        let cosPhi = cos(phi)
        let sinPhi = sin(phi)
        let halfX = (start.x - end.x) / 2
        let halfY = (start.y - end.y) / 2
        let x1 = cosPhi * halfX + sinPhi * halfY
        let y1 = -sinPhi * halfX + cosPhi * halfY
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 {
            rx *= lambda.squareRoot()
            ry *= lambda.squareRoot()
        }
        let numerator = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
        let coefficient = (max(numerator / denominator, 0)).squareRoot() * (arc.large == arc.sweep ? -1 : 1)
        let centerX = coefficient * rx * y1 / ry
        let centerY = -coefficient * ry * x1 / rx
        rotation = phi
        radii = CGSize(width: rx, height: ry)
        center = CGPoint(
            x: cosPhi * centerX - sinPhi * centerY + (start.x + end.x) / 2,
            y: sinPhi * centerX + cosPhi * centerY + (start.y + end.y) / 2
        )
        let from = CGPoint(x: (x1 - centerX) / rx, y: (y1 - centerY) / ry)
        let to = CGPoint(x: (-x1 - centerX) / rx, y: (-y1 - centerY) / ry)
        theta = Self.angle(CGPoint(x: 1, y: 0), from)
        var delta = Self.angle(from, to)
        if !arc.sweep, delta > 0 {
            delta -= Self.fullTurn
        } else if arc.sweep, delta < 0 {
            delta += Self.fullTurn
        }
        self.delta = delta
    }

    fileprivate func fitted(using fit: CGAffineTransform) -> Self {
        var result = self
        result.center = center.applying(fit)
        result.fitScale = CGSize(width: fitScale.width * fit.a, height: fitScale.height * fit.d)
        return result
    }

    func interpolated(to target: Self, at progress: CGFloat) -> Self {
        func mix(_ from: CGFloat, _ to: CGFloat) -> CGFloat {
            from + (to - from) * progress
        }
        let startRotation = radii.width == radii.height ? target.rotation : rotation
        let targetRotation = target.radii.width == target.radii.height ? startRotation : target.rotation
        let rotationTurn = (targetRotation - startRotation).remainder(dividingBy: .pi)
        let startTheta = theta + (rotation - startRotation)
        let targetTheta = target.theta + (target.rotation - (startRotation + rotationTurn))
        let thetaTurn = (targetTheta - startTheta).remainder(dividingBy: Self.fullTurn)
        var result = self
        result.center = CGPoint(x: mix(center.x, target.center.x), y: mix(center.y, target.center.y))
        result.radii = CGSize(
            width: mix(radii.width, target.radii.width),
            height: mix(radii.height, target.radii.height)
        )
        result.fitScale = CGSize(
            width: mix(fitScale.width, target.fitScale.width), height: mix(fitScale.height, target.fitScale.height)
        )
        result.rotation = startRotation + rotationTurn * progress
        result.theta = startTheta + thetaTurn * progress
        result.delta = max(-Self.fullTurn, min(Self.fullTurn, mix(delta, target.delta)))
        return result
    }

    func path() -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: cos(theta), y: sin(theta)).applying(transform))
        appendCurves(segments: Self.fullTurnSegments) { end, first, second in
            path.addCurve(to: end, control1: first, control2: second)
        }
        return path
    }

    fileprivate func appendCurves(
        segments: Int, endingAt end: CGPoint? = nil, append: (CGPoint, CGPoint, CGPoint) -> Void
    ) {
        let transform = transform
        let step = delta / CGFloat(segments)
        let handle = 4 / 3 * tan(step / 4)
        for index in 0 ..< segments {
            let a1 = theta + CGFloat(index) * step
            let a2 = a1 + step
            let first = CGPoint(x: cos(a1) - handle * sin(a1), y: sin(a1) + handle * cos(a1))
            let second = CGPoint(x: cos(a2) + handle * sin(a2), y: sin(a2) - handle * cos(a2))
            let endpoint = CGPoint(x: cos(a2), y: sin(a2)).applying(transform)
            append(
                index == segments - 1 ? end ?? endpoint : endpoint,
                first.applying(transform),
                second.applying(transform)
            )
        }
    }

    private static func angle(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        atan2(lhs.x * rhs.y - lhs.y * rhs.x, lhs.x * rhs.x + lhs.y * rhs.y)
    }
}
