// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

enum MonitorArrangementGeometry {
    private struct FitTransform {
        let scale: CGFloat
        let bounds: CGRect
        let offset: CGPoint
        let canvas: CGSize
    }

    static func canvasRects(forFramesYUp framesYUp: [CGRect], in canvas: CGSize, padding: CGFloat) -> [CGRect] {
        guard !framesYUp.isEmpty else { return [] }
        let transform = fitTransform(framesYUp: framesYUp, canvas: canvas, padding: padding)
        return framesYUp.map { frame in
            let topLeft = canvasPoint(
                forLogicalPointYUp: CGPoint(x: frame.minX, y: frame.maxY),
                transform: transform
            )
            return CGRect(
                x: topLeft.x,
                y: topLeft.y,
                width: frame.width * transform.scale,
                height: frame.height * transform.scale
            )
        }
    }

    private static func canvasPoint(forLogicalPointYUp point: CGPoint, transform: FitTransform) -> CGPoint {
        let localX = point.x - transform.bounds.minX
        let flippedY = transform.bounds.maxY - point.y
        return CGPoint(
            x: transform.offset.x + localX * transform.scale,
            y: transform.offset.y + flippedY * transform.scale
        )
    }

    private static func fitTransform(framesYUp: [CGRect], canvas: CGSize, padding: CGFloat) -> FitTransform {
        let bounds = boundingBox(of: framesYUp)
        let inset = max(0, padding)
        let availableWidth = canvas.width - inset * 2
        let availableHeight = canvas.height - inset * 2

        guard
            availableWidth > 0,
            availableHeight > 0,
            bounds.width > 0,
            bounds.height > 0
        else {
            return FitTransform(scale: 0, bounds: bounds, offset: .zero, canvas: canvas)
        }

        let scale = min(availableWidth / bounds.width, availableHeight / bounds.height)
        let scaledWidth = bounds.width * scale
        let scaledHeight = bounds.height * scale
        let offset = CGPoint(
            x: (canvas.width - scaledWidth) / 2,
            y: (canvas.height - scaledHeight) / 2
        )
        return FitTransform(scale: scale, bounds: bounds, offset: offset, canvas: canvas)
    }

    struct GridFit: Equatable {
        let cellSize: CGSize
        let origin: CGPoint
    }

    static func gridFit(columns: Int, rows: Int, in canvas: CGSize, padding: CGFloat, spacing: CGFloat) -> GridFit {
        let columnCount = max(1, columns)
        let rowCount = max(1, rows)
        let inset = max(0, padding)
        let availableWidth = max(0, canvas.width - inset * 2 - spacing * CGFloat(columnCount - 1))
        let availableHeight = max(0, canvas.height - inset * 2 - spacing * CGFloat(rowCount - 1))
        let side = max(0, min(availableWidth / CGFloat(columnCount), availableHeight / CGFloat(rowCount)))
        let gridWidth = side * CGFloat(columnCount) + spacing * CGFloat(columnCount - 1)
        let gridHeight = side * CGFloat(rowCount) + spacing * CGFloat(rowCount - 1)
        let origin = CGPoint(x: (canvas.width - gridWidth) / 2, y: (canvas.height - gridHeight) / 2)
        return GridFit(cellSize: CGSize(width: side, height: side), origin: origin)
    }

    static func cellFrame(column: Int, row: Int, fit: GridFit, spacing: CGFloat) -> CGRect {
        CGRect(
            x: fit.origin.x + CGFloat(column) * (fit.cellSize.width + spacing),
            y: fit.origin.y + CGFloat(row) * (fit.cellSize.height + spacing),
            width: fit.cellSize.width,
            height: fit.cellSize.height
        )
    }

    static func nearestCell(toPoint point: CGPoint, fit: GridFit, spacing: CGFloat) -> (column: Int, row: Int) {
        guard fit.cellSize.width > 0, fit.cellSize.height > 0 else { return (0, 0) }
        let column = ((point.x - fit.origin.x) / (fit.cellSize.width + spacing)).rounded()
        let row = ((point.y - fit.origin.y) / (fit.cellSize.height + spacing)).rounded()
        return (Int(column), Int(row))
    }

    private static func boundingBox(of frames: [CGRect]) -> CGRect {
        var minX = CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude
        for frame in frames {
            minX = min(minX, frame.minX)
            minY = min(minY, frame.minY)
            maxX = max(maxX, frame.maxX)
            maxY = max(maxY, frame.maxY)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
