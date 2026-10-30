// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

@MainActor
final class QuakeWindowInteraction {
    private let resizeEdgeThreshold: CGFloat = 8.0

    private enum InteractionMode {
        case terminal
        case windowMove(startOrigin: CGPoint, startMouseLocation: CGPoint)
        case windowResize(edges: ResizeEdge, startFrame: NSRect, startMouseLocation: CGPoint)
    }

    private var interactionMode: InteractionMode = .terminal
    private(set) var isInteracting: Bool = false

    func handleMouseDown(_ event: NSEvent, in view: NSView) -> Bool {
        guard let window = view.window else { return false }

        let point = view.convert(event.locationInWindow, from: nil)
        let edges = detectResizeEdges(at: point, in: view)

        if !edges.isEmpty {
            isInteracting = true
            interactionMode = .windowResize(
                edges: edges,
                startFrame: window.frame,
                startMouseLocation: NSEvent.mouseLocation
            )
            return true
        }

        if event.modifierFlags.isSuperset(of: [.command, .option]) {
            isInteracting = true
            interactionMode = .windowMove(startOrigin: window.frame.origin, startMouseLocation: NSEvent.mouseLocation)
            NSCursor.closedHand.set()
            return true
        }

        return false
    }

    func handleMouseUp(in view: NSView, onFrameChanged: ((NSRect) -> Void)?) -> Bool {
        switch interactionMode {
        case .terminal:
            return false
        case let .windowMove(startOrigin, _):
            if let frame = view.window?.frame,
               let changedFrame = QuakeTerminalGeometryPolicy.changedFrame(
                   from: CGRect(origin: startOrigin, size: frame.size),
                   to: frame
               )
            {
                onFrameChanged?(changedFrame)
            }
            NSCursor.arrow.set()
        case let .windowResize(_, startFrame, _):
            if let frame = view.window?.frame,
               let changedFrame = QuakeTerminalGeometryPolicy.changedFrame(from: startFrame, to: frame)
            {
                onFrameChanged?(changedFrame)
            }
            NSCursor.arrow.set()
        }
        return true
    }

    func finishMouseUp() {
        isInteracting = false
        interactionMode = .terminal
    }

    func updateCursor(for event: NSEvent, in view: NSView) {
        let point = view.convert(event.locationInWindow, from: nil)
        let edges = detectResizeEdges(at: point, in: view)

        if !edges.isEmpty {
            edges.cursor.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    func handleMouseDrag(in view: NSView) -> Bool {
        switch interactionMode {
        case .terminal:
            return false
        case let .windowMove(startOrigin, startMouseLocation):
            let current = NSEvent.mouseLocation
            let delta = CGPoint(x: current.x - startMouseLocation.x, y: current.y - startMouseLocation.y)
            view.window?.setFrameOrigin(CGPoint(x: startOrigin.x + delta.x, y: startOrigin.y + delta.y))
        case let .windowResize(edges, startFrame, startMouseLocation):
            let current = NSEvent.mouseLocation
            let delta = CGPoint(x: current.x - startMouseLocation.x, y: current.y - startMouseLocation.y)
            let newFrame = calculateResizedFrame(startFrame: startFrame, edges: edges, delta: delta)
            view.window?.setFrame(newFrame, display: true)
        }
        return true
    }

    private func detectResizeEdges(at point: CGPoint, in view: NSView) -> ResizeEdge {
        GhosttySurfaceResizeEdgeClassifier.classifyEdges(
            at: point,
            localBounds: view.bounds,
            paneFrame: view.frame,
            containerBounds: view.superview?.bounds ?? view.frame,
            threshold: resizeEdgeThreshold
        )
    }

    private func calculateResizedFrame(startFrame: NSRect, edges: ResizeEdge, delta: CGPoint) -> NSRect {
        var frame = startFrame
        let minWidth: CGFloat = 200
        let minHeight: CGFloat = 100

        if edges.contains(.right) {
            frame.size.width = max(minWidth, startFrame.width + delta.x)
        }
        if edges.contains(.left) {
            let proposed = startFrame.width - delta.x
            if proposed >= minWidth {
                frame.origin.x = startFrame.origin.x + delta.x
                frame.size.width = proposed
            }
        }
        if edges.contains(.top) {
            frame.size.height = max(minHeight, startFrame.height + delta.y)
        }
        if edges.contains(.bottom) {
            let proposed = startFrame.height - delta.y
            if proposed >= minHeight {
                frame.origin.y = startFrame.origin.y + delta.y
                frame.size.height = proposed
            }
        }
        return frame
    }
}

struct GhosttySurfaceResizeEdgeClassifier {
    private static let perimeterTolerance: CGFloat = 0.5

    static func classifyEdges(
        at point: CGPoint,
        localBounds: CGRect,
        paneFrame: CGRect,
        containerBounds: CGRect,
        threshold: CGFloat
    ) -> ResizeEdge {
        var edges: ResizeEdge = []

        if point.x <= threshold,
           abs(paneFrame.minX - containerBounds.minX) <= perimeterTolerance
        {
            edges.insert(.left)
        } else if point.x >= localBounds.width - threshold,
                  abs(paneFrame.maxX - containerBounds.maxX) <= perimeterTolerance
        {
            edges.insert(.right)
        }

        if point.y <= threshold,
           abs(paneFrame.minY - containerBounds.minY) <= perimeterTolerance
        {
            edges.insert(.bottom)
        } else if point.y >= localBounds.height - threshold,
                  abs(paneFrame.maxY - containerBounds.maxY) <= perimeterTolerance
        {
            edges.insert(.top)
        }

        return edges
    }
}
