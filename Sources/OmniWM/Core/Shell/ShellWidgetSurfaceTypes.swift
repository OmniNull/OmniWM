// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Carbon
import OmniWMScriptHost
import OmniWMShellCore
import QuartzCore

@MainActor
final class ShellWidgetLayout {
    static let nodeCapacity = 4096

    private static let scratch: UnsafeMutablePointer<TreeNode> = {
        let nodes = UnsafeMutablePointer<TreeNode>.allocate(capacity: nodeCapacity)
        nodes.initialize(repeating: TreeNode(kind: .group, subtreeEnd: 1), count: nodeCapacity)
        return nodes
    }()

    private(set) var core = SurfaceCore(capacity: 128)
    private(set) var patches = PatchBuffer(capacity: 256)

    var size: CGSize {
        let frame = core.rootFrame
        return CGSize(width: CGFloat(frame.width), height: CGFloat(frame.height))
    }

    var naturalSize: CGSize {
        let size = core.rootSize
        return CGSize(width: CGFloat(size.width), height: CGFloat(size.height))
    }

    func apply(_ output: [UInt8], text: ShellTextStore) -> Bool {
        let nodes = Self.scratch
        let count = output.withUnsafeBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            return ShellWireDecoder.decode(base, length: buffer.count, into: nodes, capacity: Self.nodeCapacity)
        }
        guard count > 0 else { return false }
        patches.removeAll()
        core.apply(
            UnsafeBufferPointer(start: nodes, count: count),
            measure: shellMeasureText,
            context: UnsafeMutableRawPointer(text.table),
            into: &patches
        )
        return true
    }

    func scroll(_ handle: ElementHandle, by delta: Float) -> Float? {
        core.scroll(handle, by: delta)
    }

    func setRootBleed(_ bleed: Insets) {
        patches.removeAll()
        core.setRootBleed(bleed, into: &patches)
    }

    func setRootLimit(_ limit: Size2) {
        patches.removeAll()
        core.setRootLimit(limit, into: &patches)
    }

    func reset() {
        patches.removeAll()
        core.apply(
            UnsafeBufferPointer(start: Self.scratch, count: 0),
            measure: shellMeasureText,
            context: nil,
            into: &patches
        )
    }
}

struct ShellPopoutChrome: Equatable {
    var glass = false
    var clear = false
    var radius: CGFloat = 10
}

enum ShellFocusAxis {
    case horizontal
    case vertical
}

struct ShellAnchor {
    let frame: CGRect
    let level: NSWindow.Level
    var container: CGRect?
}

struct ShellClick {
    let action: UInt32
    let opensPopout: Bool
    let anchor: ShellAnchor
    let event: ShellEvent
    var target: UInt32 = 0
    var source = ElementHandle.none
    var sequence: Int?
}

extension ShellEvent {
    init(button: Button, modifiers: NSEvent.ModifierFlags) {
        self.init(
            button: button,
            shift: modifiers.contains(.shift),
            option: modifiers.contains(.option),
            control: modifiers.contains(.control),
            command: modifiers.contains(.command)
        )
    }

    func acts(on content: Content) -> Bool {
        action(of: content) != 0
    }

    func action(of content: Content) -> UInt32 {
        switch button {
        case .right: content.secondaryAction
        case .none: content.scrollAction
        case .left,
             .middle: content.action
        }
    }
}

struct ShellMenuEvent {
    let target: UInt32
    let anchor: ShellAnchor
    var label: CGRect?
}

struct ShellPreviewEvent {
    let target: UInt32
    let anchor: ShellAnchor?
}

struct ShellTooltipEvent {
    let text: UInt32
    let location: CGPoint
}

enum ShellDragEvent {
    case began(target: UInt32, at: CGPoint)
    case moved(CGPoint)
    case ended(CGPoint)
}

struct ShellTargetFrame {
    let target: UInt32
    let frame: CGRect
    let drop: Bool
}
