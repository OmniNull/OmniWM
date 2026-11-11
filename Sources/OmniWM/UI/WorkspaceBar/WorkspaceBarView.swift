// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

@MainActor
struct WorkspaceBarView: View {
    let model: WorkspaceBarModel
    var slice: WorkspaceBarIslandSlice = .all
    @Bindable var motionPolicy: MotionPolicy
    var shellSurface: ((String) -> NSView?)?
    var shaderBackground: (() -> NSView?)?

    var body: some View {
        if model.snapshot.orientation.isVertical, model.zones == nil {
            ScrollView(.vertical) {
                content.fixedSize(horizontal: false, vertical: true)
            }
            .scrollIndicators(.hidden)
            .frame(width: model.snapshot.barHeight)
        } else {
            content
        }
    }

    private var content: some View {
        WorkspaceBarContentView(
            snapshot: model.snapshot,
            slice: slice,
            hiddenBarJoinEdge: slice == .secondary ? nil : model.hiddenBarJoinEdge,
            zones: model.zones,
            animationsEnabled: motionPolicy.animationsEnabled,
            shellSurface: shellSurface,
            shaderBackground: shaderBackground
        )
    }
}

extension WorkspaceBarView {
    static func contentThickness(forBarHeight barHeight: CGFloat) -> CGFloat {
        max(16, barHeight - 4) + 4
    }

    static func barShape(
        joinedAt edge: PopupAttachment.Edge?,
        radius: CGFloat = WorkspaceBarGeometry.cornerRadius
    ) -> UnevenRoundedRectangle {
        return UnevenRoundedRectangle(
            topLeadingRadius: edge == .above || edge == .left ? 0 : radius,
            bottomLeadingRadius: edge == .below || edge == .left ? 0 : radius,
            bottomTrailingRadius: edge == .below || edge == .right ? 0 : radius,
            topTrailingRadius: edge == .above || edge == .right ? 0 : radius,
            style: .continuous
        )
    }
}

@MainActor
struct WorkspaceBarMeasurementView: View {
    let snapshot: WorkspaceBarSnapshot
    var slice: WorkspaceBarIslandSlice = .all

    var body: some View {
        WorkspaceBarContentView(snapshot: snapshot, slice: slice, animationsEnabled: false)
            .fixedSize(horizontal: !snapshot.orientation.isVertical, vertical: snapshot.orientation.isVertical)
    }
}

@MainActor
private struct WorkspaceBarContentView: View {
    let snapshot: WorkspaceBarSnapshot
    var slice: WorkspaceBarIslandSlice = .all
    var hiddenBarJoinEdge: PopupAttachment.Edge?
    var zones: WorkspaceBarZones?
    let animationsEnabled: Bool
    var shellSurface: ((String) -> NSView?)?
    var shaderBackground: (() -> NSView?)?

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.colorScheme) private var colorScheme

    private var barShape: UnevenRoundedRectangle {
        WorkspaceBarView.barShape(
            joinedAt: hiddenBarJoinEdge,
            radius: zones != nil || snapshot.backgroundStyle == .solidBlack ? 0 : WorkspaceBarGeometry.cornerRadius
        )
    }

    var body: some View {
        let thickness = WorkspaceBarView.contentThickness(forBarHeight: snapshot.barHeight)
        widgets
            .frame(
                width: snapshot.orientation.isVertical ? thickness : nil,
                height: snapshot.orientation.isVertical ? nil : thickness
            )
            .background { background }
            .animation(
                animationsEnabled && hiddenBarJoinEdge == nil ? .easeOut(duration: 0.12) : nil,
                value: hiddenBarJoinEdge
            )
            .environment(\.layoutDirection, .leftToRight)
    }

    @ViewBuilder
    private var widgets: some View {
        if let zones {
            WorkspaceBarZoneLayout(zones: zones, vertical: snapshot.orientation.isVertical) {
                slots
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            snapshot.orientation.stack(spacing: 8) {
                slots
            }
            .padding(snapshot.orientation.isVertical ? .vertical : .horizontal, 4)
            .frame(maxWidth: snapshot.backgroundStyle == .solidBlack ? .infinity : nil, alignment: .leading)
        }
    }

    private var slots: some View {
        ForEach(ShellLane.allCases, id: \.self) { lane in
            ForEach(slice.shellWidgets(in: snapshot, lane: lane)) { widget in
                ShellWidgetSlot(widget: widget, view: shellSurface?(widget.id), cuttable: zones != nil)
                    .layoutValue(key: WorkspaceBarZoneLayout.Lane.self, value: lane)
                    .layoutValue(key: WorkspaceBarZoneLayout.Priority.self, value: widget.priority)
            }
        }
    }

    @ViewBuilder
    private var background: some View {
        let style = snapshot.backgroundStyle
        let outline = style.outline(contrast: colorSchemeContrast, colorScheme: colorScheme)
        if style != .transparent {
            WorkspaceBarSurfaceFill(
                shape: barShape,
                backgroundStyle: style,
                backgroundOpacity: snapshot.backgroundOpacity
            )
            if style != .solidBlack, snapshot.barShader != nil, let view = shaderBackground?() {
                WorkspaceBarShaderBackground(view: view)
                    .id(ObjectIdentifier(view))
                    .clipShape(barShape)
                    .opacity(snapshot.backgroundOpacity)
            }
            if let outline, zones == nil || style != .material {
                barShape.strokeBorder(outline.color, lineWidth: outline.width)
            }
        }
    }
}

@MainActor
private struct WorkspaceBarShaderBackground: NSViewRepresentable {
    let view: NSView

    func makeNSView(context _: Context) -> NSView {
        view
    }

    func updateNSView(_: NSView, context _: Context) {}
}
