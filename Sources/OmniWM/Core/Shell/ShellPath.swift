// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

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

    func path(fitting viewBox: CGRect?, into size: CGSize) -> CGPath {
        var transform = CGAffineTransform.identity
        if let viewBox, viewBox.width > 0, viewBox.height > 0 {
            transform = CGAffineTransform(scaleX: size.width / viewBox.width, y: size.height / viewBox.height)
                .translatedBy(x: -viewBox.minX, y: -viewBox.minY)
        }
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
        return parser.path.elements.isEmpty ? nil : parser.path
    }

    private struct Parser {
        var reader: Reader
        var path = ShellPathData()
        var current = CGPoint.zero
        var start = CGPoint.zero
        var cubic: CGPoint?
        var quadratic: CGPoint?

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
            ShellPath.addArc(arc, to: &path, from: current, to: end)
            current = end
            return true
        }
    }

    private struct Arc {
        let radii: CGSize
        let rotation: CGFloat
        let large: Bool
        let sweep: Bool
    }

    private struct ArcGeometry {
        let center: CGPoint
        let rx: CGFloat
        let ry: CGFloat
        let cosPhi: CGFloat
        let sinPhi: CGFloat
        let theta: CGFloat
        let delta: CGFloat

        init(_ arc: Arc, from start: CGPoint, to end: CGPoint) {
            var rx = abs(arc.radii.width)
            var ry = abs(arc.radii.height)
            let phi = arc.rotation * .pi / 180
            cosPhi = cos(phi)
            sinPhi = sin(phi)
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
            center = CGPoint(
                x: cosPhi * centerX - sinPhi * centerY + (start.x + end.x) / 2,
                y: sinPhi * centerX + cosPhi * centerY + (start.y + end.y) / 2
            )
            self.rx = rx
            self.ry = ry
            let from = CGPoint(x: (x1 - centerX) / rx, y: (y1 - centerY) / ry)
            let to = CGPoint(x: (-x1 - centerX) / rx, y: (-y1 - centerY) / ry)
            theta = ShellPath.angle(CGPoint(x: 1, y: 0), from)
            var delta = ShellPath.angle(from, to)
            if !arc.sweep, delta > 0 {
                delta -= 2 * .pi
            } else if arc.sweep, delta < 0 {
                delta += 2 * .pi
            }
            self.delta = delta
        }

        func point(_ unit: CGPoint) -> CGPoint {
            CGPoint(
                x: center.x + rx * cosPhi * unit.x - ry * sinPhi * unit.y,
                y: center.y + rx * sinPhi * unit.x + ry * cosPhi * unit.y
            )
        }
    }

    private static func addArc(_ arc: Arc, to path: inout ShellPathData, from start: CGPoint, to end: CGPoint) {
        guard start != end else { return }
        guard abs(arc.radii.width) > 0, abs(arc.radii.height) > 0 else {
            path.addLine(to: end)
            return
        }
        let geometry = ArcGeometry(arc, from: start, to: end)
        let segments = max(Int((abs(geometry.delta) / (.pi / 2)).rounded(.up)), 1)
        let step = geometry.delta / CGFloat(segments)
        let handle = 4 / 3 * tan(step / 4)
        for index in 0 ..< segments {
            let a1 = geometry.theta + CGFloat(index) * step
            let a2 = a1 + step
            let first = CGPoint(x: cos(a1) - handle * sin(a1), y: sin(a1) + handle * cos(a1))
            let second = CGPoint(x: cos(a2) + handle * sin(a2), y: sin(a2) - handle * cos(a2))
            path.addCurve(
                to: index == segments - 1 ? end : geometry.point(CGPoint(x: cos(a2), y: sin(a2))),
                control1: geometry.point(first),
                control2: geometry.point(second)
            )
        }
    }

    private static func angle(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        atan2(lhs.x * rhs.y - lhs.y * rhs.x, lhs.x * rhs.x + lhs.y * rhs.y)
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
