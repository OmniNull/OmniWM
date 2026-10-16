// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import OmniWMScriptHost
import OmniWMShellCore

enum ShellWireDecoder {
    static let symbolSize: Float = 14
    static let iconSize: Float = 16
    static let progressSize = Size2(width: 30, height: 4)
    static let sliderSize = Size2(width: 100, height: 16)

    static func decode(
        _ base: UnsafeRawPointer,
        length: Int,
        into nodes: UnsafeMutablePointer<TreeNode>,
        capacity: Int
    ) -> Int {
        guard length >= MemoryLayout<omni_wire_header>.stride else { return 0 }
        let header = base.loadUnaligned(as: omni_wire_header.self)
        let count = Int(header.node_count)
        guard header.magic == OMNI_WIRE_MAGIC,
              count <= capacity,
              MemoryLayout<omni_wire_header>.stride + count * MemoryLayout<omni_wire_node>.stride <= length
        else {
            return 0
        }
        let wire = base + MemoryLayout<omni_wire_header>.stride
        for index in 0 ..< count {
            let node = (wire + index * MemoryLayout<omni_wire_node>.stride).loadUnaligned(as: omni_wire_node.self)
            guard node.subtree_end > Int32(index), Int(node.subtree_end) <= count else { return 0 }
            nodes[index] = treeNode(node)
        }
        return count
    }

    static func rootTiming(_ output: [UInt8]) -> ShellTiming {
        output.withUnsafeBytes { buffer in
            let headerSize = MemoryLayout<omni_wire_header>.stride
            guard buffer.count >= headerSize + MemoryLayout<omni_wire_node>.stride,
                  buffer.loadUnaligned(as: omni_wire_header.self).node_count > 0
            else {
                return ShellTiming()
            }
            let root = buffer.loadUnaligned(fromByteOffset: headerSize, as: omni_wire_node.self)
            return ShellTiming(open: root.open_duration, close: root.close_duration)
        }
    }

    private static func textStyle(_ wire: omni_wire_node) -> UInt32 {
        UInt32(wire.style) | UInt32(wire.text_size) << OMNI_STYLE_SIZE_SHIFT
    }

    private static func iconSource(_ flags: UInt16) -> IconSource {
        switch UInt32(flags) & OMNI_NODE_ICON_MASK {
        case OMNI_NODE_ICON_WINDOW: .window
        case OMNI_NODE_ICON_PID: .pid
        default: .bundle
        }
    }

    private static func treeNode(_ wire: omni_wire_node) -> TreeNode {
        let kind = ElementKind(rawValue: wire.kind) ?? .group
        return TreeNode(
            kind: kind,
            subtreeEnd: wire.subtree_end,
            key: wire.key,
            layout: layoutStyle(wire, kind: kind),
            paint: paint(wire),
            content: content(wire, kind: kind)
        )
    }

    @inline(__always) private static func layoutStyle(_ wire: omni_wire_node, kind: ElementKind) -> LayoutStyle {
        var layout = LayoutStyle(
            axis: Axis(rawValue: wire.axis) ?? .row,
            width: wire.width,
            height: wire.height,
            grow: wire.grow,
            gap: wire.gap,
            padding: wire.padding,
            centerCross: wire.center_cross != 0,
            align: UInt8(truncatingIfNeeded: (UInt32(wire.flags) & OMNI_NODE_ALIGN_MASK) >> OMNI_NODE_ALIGN_SHIFT),
            dx: wire.dx,
            dy: wire.dy
        )
        if kind == .symbol || kind == .image || kind == .bitmap {
            let size = kind == .symbol ? ShellTextStyle.symbolSize(for: textStyle(wire)) : iconSize
            layout.width = layout.width >= 0 ? layout.width : size
            layout.height = layout.height >= 0 ? layout.height : size
        } else if kind == .progress || kind == .slider {
            let size = kind == .slider ? sliderSize : progressSize
            layout.width = layout.width >= 0 ? layout.width : size.width
            layout.height = layout.height >= 0 ? layout.height : size.height
        } else if kind == .input {
            layout.width = layout.width >= 0 ? layout.width : 180
            layout.height = layout.height >= 0 ? layout
                .height : (UInt32(wire.input_flags) & OMNI_INPUT_MULTILINE != 0 ? 80 : 26)
        }
        return layout
    }

    @inline(__always) private static func paint(_ wire: omni_wire_node) -> Paint {
        Paint(
            fill: Color(packed: wire.fill, role: wire.fill_role),
            stroke: Color(packed: wire.stroke, role: wire.stroke_role),
            strokeWidth: wire.stroke_width,
            cornerRadius: wire.corner_radius,
            opacity: wire.opacity,
            scale: wire.scale,
            shadow: Color(packed: wire.shadow, role: wire.shadow_role),
            shadowRadius: wire.shadow_radius,
            material: UInt8(truncatingIfNeeded: (UInt32(wire.flags) & OMNI_NODE_MATERIAL_MASK) >>
                OMNI_NODE_MATERIAL_SHIFT),
            blurRadius: wire.blur_radius,
            saturation: wire.saturation,
            enter: Enter(
                opacity: wire.enter_opacity,
                scale: wire.enter_scale,
                dx: wire.enter_dx,
                dy: wire.enter_dy,
                from: Float(wire.enter_from) / 255,
                to: Float(wire.enter_to) / 255,
                curve: wire.enter_curve,
                curveRef: wire.enter_curve_ref,
                path: wire.enter_path,
                stretch: wire.enter_stretch
            ),
            masks: UInt32(wire.options) & OMNI_NODE_OPTION_MASK != 0,
            rotate: wire.rotate,
            loop: wire.loop,
            loopPaused: UInt32(wire.options) & OMNI_NODE_OPTION_LOOP_PAUSED != 0,
            speed: wire.speed > 0 ? wire.speed : 1,
            appear: wire.appear,
            exit: wire.exit
        )
    }

    @inline(__always) private static func content(_ wire: omni_wire_node, kind: ElementKind) -> Content {
        var content = Content(
            text: wire.text,
            reserve: wire.reserve,
            style: textStyle(wire),
            color: Color(packed: wire.color, role: wire.color_role),
            value: wire.series,
            action: wire.action,
            hover: Color(packed: wire.hover, role: wire.hover_role),
            motion: wire.motion,
            opensPopout: wire.flags & UInt16(OMNI_NODE_OPENS_POPOUT) != 0,
            params: kind == .path
                ? SIMD4(wire.view_box.0, wire.view_box.1, wire.view_box.2, wire.view_box.3)
                : SIMD4(wire.params.0, wire.params.1, wire.params.2, wire.params.3),
            rate: UInt8(clamping: wire.rate),
            target: wire.target,
            menu: wire.flags & UInt16(OMNI_NODE_MENU) != 0,
            preview: wire.flags & UInt16(OMNI_NODE_PREVIEW) != 0,
            drag: wire.flags & UInt16(OMNI_NODE_DRAG) != 0,
            drop: wire.flags & UInt16(OMNI_NODE_DROP) != 0,
            secondaryAction: wire.secondary_action,
            scrollAction: wire.scroll_action,
            maxWidth: wire.max_width,
            iconSource: iconSource(wire.flags),
            iconRef: wire.icon_ref,
            placeholder: wire.placeholder,
            hoverScale: wire.hover_scale,
            hoverOpacity: wire.hover_opacity,
            help: wire.help,
            hoverMotion: wire.hover_motion,
            motionCurve: wire.motion_curve,
            motionCurveRef: wire.motion_curve_ref,
            trail: UInt32(wire.options) & OMNI_NODE_OPTION_TRAIL != 0,
            hoverMaterial: wire.hover_material,
            lines: wire.lines,
            scrolls: wire.flags & UInt16(OMNI_NODE_SCROLL) != 0,
            bridges: UInt32(wire.options) & OMNI_NODE_OPTION_BRIDGE != 0,
            openDuration: wire.open_duration,
            closeDuration: wire.close_duration,
            evenOdd: UInt32(wire.options) & OMNI_NODE_OPTION_EVEN_ODD != 0,
            attaches: UInt32(wire.options) & OMNI_NODE_OPTION_ATTACH != 0,
            audio: UInt32(wire.options) & OMNI_NODE_OPTION_AUDIO != 0
        )
        applyInteraction(wire, to: &content)
        applyGesture(wire, to: &content)
        applyResources(wire, to: &content)
        return content
    }

    @inline(__always) private static func applyInteraction(_ wire: omni_wire_node, to content: inout Content) {
        content.hoverAction = wire.hover_action
        content.pressAction = wire.press_action
        content.gestureAction = wire.gesture_action
        content.gestureTrack = wire.gesture_track
        content.keyAction = wire.key_action
        content.outsidePressAction = wire.outside_press_action
        content.keys = wire.keys
        content.pressScale = wire.press_scale
        content.pressScaleSpecified = UInt32(wire.input_flags) & OMNI_INPUT_PRESS_SCALE != 0
        content.pressOpacity = wire.press_opacity
        content.pressFill = Color(packed: wire.press_fill, role: wire.press_fill_role)
        content.pressFillSpecified = UInt32(wire.input_flags) & OMNI_INPUT_PRESS_FILL != 0
        content.pressMotion = wire.press_motion
        content.pressMotionCurve = wire.press_motion_curve
        content.pressMotionCurveRef = wire.press_motion_curve_ref
        content.hoverDelay = wire.hover_delay
        content.hoverGrace = wire.hover_grace
        content.focusable = UInt32(wire.input_flags) & OMNI_INPUT_FOCUSABLE != 0
        content.focusRing = UInt32(wire.options) & OMNI_NODE_OPTION_NO_FOCUS_RING == 0
        content.scrollMomentum = UInt32(wire.input_flags) & OMNI_INPUT_MOMENTUM_DELIVER != 0
        content.inputCommitAction = wire.input_commit_action
        content.inputCancelAction = wire.input_cancel_action
        content.inputFocusAction = wire.input_focus_action
        content.inputMaxLength = wire.input_max_length
        content.inputMultiline = UInt32(wire.input_flags) & OMNI_INPUT_MULTILINE != 0
        content.inputFocus = UInt32(wire.input_flags) & OMNI_INPUT_FOCUS_PRESENT == 0 ? -1 :
            (UInt32(wire.input_flags) & OMNI_INPUT_FOCUS_VALUE != 0 ? 1 : 0)
    }

    @inline(__always) private static func applyGesture(_ wire: omni_wire_node, to content: inout Content) {
        content.gesture = ShellGestureConfig(
            axis: ShellGestureConfig.Axis(rawValue: wire.gesture_axis) ?? .none,
            source: ShellGestureConfig.Source(rawValue: wire.gesture_source) ?? .pointer,
            direction: ShellGestureConfig.Direction(rawValue: wire.gesture_direction) ?? .any,
            threshold: wire.gesture_threshold,
            lockDistance: wire.gesture_lock_distance,
            dominance: wire.gesture_dominance,
            commitDistance: wire.gesture_commit_distance,
            commitVelocity: wire.gesture_commit_velocity,
            eventsAll: UInt32(wire.input_flags) & OMNI_INPUT_GESTURE_ALL != 0
        )
    }

    @inline(__always) private static func applyResources(_ wire: omni_wire_node, to content: inout Content) {
        content.textureRef = wire.texture_ref
        content.resourceImageRef = wire.resource_image_ref
        content.thumbnail = wire.thumbnail
        content.resourceDropAction = wire.resource_drop_action
        content.resourceHoverAction = wire.resource_hover_action
        content.resourceAccepts = wire.resource_accepts
        content.dragItemsRef = wire.resource_drag_ref
        content.dragOutAction = wire.resource_drag_action
    }
}
