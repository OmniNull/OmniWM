// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics

enum ShellManipulationEdge: Sendable {
    case left
    case right
    case top
    case bottom

    var mask: UInt8 {
        switch self {
        case .left: 1
        case .right: 2
        case .top: 4
        case .bottom: 8
        }
    }
}

struct ShellManipulationProposal: Equatable, Sendable {
    let rect: CGRect
}

enum ShellManipulationGeometry {
    static func clamped(_ rect: CGRect, to bounds: CGRect) -> CGRect? {
        guard valid(rect), valid(bounds) else { return nil }
        let width = min(rect.width, bounds.width)
        let height = min(rect.height, bounds.height)
        return CGRect(
            x: min(max(rect.minX, bounds.minX), bounds.maxX - width),
            y: min(max(rect.minY, bounds.minY), bounds.maxY - height),
            width: width,
            height: height
        )
    }

    static func content(of rect: CGRect, recipe: ShellManipulationRecipe) -> CGRect {
        rect.insetBy(dx: rect.width * recipe.inset.width, dy: rect.height * recipe.inset.height)
    }

    static func sample(
        start: CGRect,
        translation: CGPoint,
        recipe: ShellManipulationRecipe
    ) -> CGRect? {
        switch recipe.mode {
        case .move: moved(start: start, translation: translation, recipe: recipe)
        case .resize: resized(start: start, translation: translation, recipe: recipe)
        case .scale: scaled(start: start, translation: translation, recipe: recipe)
        }
    }

    static func moved(
        start: CGRect,
        translation: CGPoint,
        recipe: ShellManipulationRecipe
    ) -> CGRect? {
        guard recipe.mode == .move, valid(translation),
              let start = bounded(start, recipe: recipe)
        else { return nil }
        return placed(start.offsetBy(dx: translation.x, dy: translation.y), recipe: recipe)
    }

    static func resized(
        start: CGRect,
        translation: CGPoint,
        recipe: ShellManipulationRecipe
    ) -> CGRect? {
        guard recipe.mode == .resize, valid(translation),
              let start = bounded(start, recipe: recipe)
        else { return nil }
        var left = start.minX
        var right = start.maxX
        var top = start.minY
        var bottom = start.maxY
        if recipe.resizeMask & ShellManipulationEdge.left.mask != 0 {
            left = min(
                max(left + translation.x, max(recipe.bounds.minX, right - recipe.maximum.width)),
                right - recipe.minimum.width
            )
        } else if recipe.resizeMask & ShellManipulationEdge.right.mask != 0 {
            right = max(
                min(right + translation.x, min(recipe.bounds.maxX, left + recipe.maximum.width)),
                left + recipe.minimum.width
            )
        }
        if recipe.resizeMask & ShellManipulationEdge.top.mask != 0 {
            top = min(
                max(top + translation.y, max(recipe.bounds.minY, bottom - recipe.maximum.height)),
                bottom - recipe.minimum.height
            )
        } else if recipe.resizeMask & ShellManipulationEdge.bottom.mask != 0 {
            bottom = max(
                min(bottom + translation.y, min(recipe.bounds.maxY, top + recipe.maximum.height)),
                top + recipe.minimum.height
            )
        }
        let result = CGRect(x: left, y: top, width: right - left, height: bottom - top)
        return valid(result) ? result : nil
    }

    static func scaled(
        start: CGRect,
        translation: CGPoint,
        recipe: ShellManipulationRecipe
    ) -> CGRect? {
        guard recipe.mode == .scale, valid(start), valid(translation) else { return nil }
        let content = content(of: start, recipe: recipe)
        let outwardX: CGFloat = recipe.resizeMask & ShellManipulationEdge.right.mask != 0 ? 1 : -1
        let outwardY: CGFloat = recipe.resizeMask & ShellManipulationEdge.bottom.mask != 0 ? 1 : -1
        let pivot = CGPoint(
            x: outwardX > 0 ? content.minX : content.maxX,
            y: outwardY > 0 ? content.minY : content.maxY
        )
        let roomX = outwardX > 0 ? recipe.bounds.maxX - pivot.x : pivot.x - recipe.bounds.minX
        let roomY = outwardY > 0 ? recipe.bounds.maxY - pivot.y : pivot.y - recipe.bounds.minY
        let lower = max(recipe.minimum.width / start.width, recipe.minimum.height / start.height)
        let upper = max(lower, min(
            min(recipe.maximum.width / start.width, recipe.maximum.height / start.height),
            min(roomX / content.width, roomY / content.height)
        ))
        let gain = 1 + (outwardX * translation.x + outwardY * translation.y) / (content.width + content.height)
        let factor = min(max(gain, lower), upper)
        let result = CGRect(
            x: pivot.x + (start.minX - pivot.x) * factor,
            y: pivot.y + (start.minY - pivot.y) * factor,
            width: start.width * factor,
            height: start.height * factor
        )
        return valid(result) ? result : nil
    }

    static func proposal(rect: CGRect, recipe: ShellManipulationRecipe) -> ShellManipulationProposal? {
        let proposed = switch recipe.mode {
        case .move,
             .resize: bounded(rect, recipe: recipe)
        case .scale: scaled(start: rect, translation: .zero, recipe: recipe)
        }
        return proposed.map(ShellManipulationProposal.init(rect:))
    }

    static func valid(_ rect: CGRect) -> Bool {
        valid(rect.origin) && rect.size.width.isFinite && rect.size.height.isFinite
            && rect.size.width > 0 && rect.size.height > 0
            && rect.maxX.isFinite && rect.maxY.isFinite
    }

    private static func bounded(_ rect: CGRect, recipe: ShellManipulationRecipe) -> CGRect? {
        guard valid(rect) else { return nil }
        return placed(CGRect(
            origin: rect.origin,
            size: CGSize(
                width: min(max(rect.width, recipe.minimum.width), recipe.maximum.width),
                height: min(max(rect.height, recipe.minimum.height), recipe.maximum.height)
            )
        ), recipe: recipe)
    }

    private static func placed(_ rect: CGRect, recipe: ShellManipulationRecipe) -> CGRect? {
        let insetX = rect.width * recipe.inset.width
        let insetY = rect.height * recipe.inset.height
        guard let content = clamped(rect.insetBy(dx: insetX, dy: insetY), to: recipe.bounds) else { return nil }
        return CGRect(x: content.minX - insetX, y: content.minY - insetY, width: rect.width, height: rect.height)
    }

    private static func valid(_ point: CGPoint) -> Bool {
        point.x.isFinite && point.y.isFinite
    }
}
