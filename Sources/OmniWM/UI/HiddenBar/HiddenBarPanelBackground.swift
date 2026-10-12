// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import SwiftUI

struct HiddenBarPanelBackground: View {
    let layout: HiddenBarPanelLayout
    let placement: HiddenBarPanelPlacement?

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    private var edge: PopupAttachment.Edge {
        placement?.attachment.edge ?? .below
    }

    private var style: WorkspaceBarSnapshot.BackgroundStyle {
        placement?.workspaceBar?.backgroundStyle ?? .material
    }

    private var liftOffset: CGSize {
        switch edge {
        case .below: CGSize(width: 0, height: 2)
        case .above: CGSize(width: 0, height: -2)
        case .right: CGSize(width: 2, height: 0)
        case .left: CGSize(width: -2, height: 0)
        }
    }

    var body: some View {
        let contour = layout.contour(edge: edge)
        ZStack {
            if layout.seam != nil, style != .transparent {
                contour.fill(Color.black)
                    .shadow(
                        color: .black.opacity(colorScheme == .dark ? 0.32 : 0.18),
                        radius: 6, x: liftOffset.width, y: liftOffset.height
                    )
                    .mask { Rectangle().subtracting(contour) }
            }
            WorkspaceBarSurfaceFill(
                shape: contour,
                backgroundStyle: style,
                backgroundOpacity: placement?.workspaceBar?.backgroundOpacity ?? 0
            )
            if style == .material {
                contour.stroke(
                    contrast == .increased ? Color.primary.opacity(0.45) : Color.secondary.opacity(0.18),
                    lineWidth: contrast == .increased ? 1 : 0.5
                )
                .mask { Rectangle().subtracting(Path(layout.seam ?? .zero)) }
            }
        }
    }
}

extension HiddenBarPanelLayout {
    func contour(edge: PopupAttachment.Edge) -> Path {
        guard let seam else { return Path(roundedRect: body, cornerRadius: 12) }
        let transform: CGAffineTransform
        switch edge {
        case .below: transform = .identity
        case .above: transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: frame.height)
        case .right: transform = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case .left: transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: frame.width, ty: 0)
        }
        return Self.contour(
            body: body.applying(transform.inverted()),
            seam: seam.applying(transform.inverted()),
            hasEars: hasEars
        ).applying(transform)
    }

    private static func contour(body: CGRect, seam: CGRect, hasEars: Bool) -> Path {
        let radius = WorkspaceBarGeometry.cornerRadius
        let reach = HiddenBarPanelPlacement.continuousCornerReach
        var path = UnevenRoundedRectangle(
            topLeadingRadius: min(radius, max(0, seam.minX - body.minX) / reach),
            bottomLeadingRadius: radius,
            bottomTrailingRadius: radius,
            topTrailingRadius: min(radius, max(0, body.maxX - seam.maxX) / reach),
            style: .continuous
        ).path(in: body)
        guard hasEars else { return path }
        for (square, circle) in [
            (body.minX - radius, body.minX - radius * 2),
            (body.maxX, body.maxX)
        ] {
            let ear = Path(CGRect(x: square, y: body.minY, width: radius, height: radius))
                .subtracting(Path(ellipseIn: CGRect(x: circle, y: body.minY, width: radius * 2, height: radius * 2)))
            path = path.union(ear)
        }
        return path
    }
}
