// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

extension NiriLayoutEngine {
    func isAccordion(in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        states[workspaceId]?.isAccordion ?? false
    }

    func setAccordion(_ enabled: Bool, in workspaceId: WorkspaceDescriptor.ID) {
        guard isAccordion(in: workspaceId) != enabled else { return }
        ensureState(for: workspaceId).isAccordion = enabled
    }

    func updateAccordionStyle(padding: CGFloat, axis: AccordionAxis) {
        assertSanctionedMutation()
        renderStyle.accordionPadding = min(max(padding, 0), 200)
        renderStyle.accordionAxis = axis
    }

    func accordionRaiseOrder(for token: WindowToken, in workspaceId: WorkspaceDescriptor.ID) -> [WindowToken] {
        guard isAccordion(in: workspaceId),
              let window = findNode(for: token, in: workspaceId),
              let column = column(of: window)
        else { return [] }
        return column.windowNodes.map(\.token).filter { $0 != token } + [token]
    }

    func layoutAccordion(
        _ columns: [NiriProjectedColumn],
        selection: NiriViewportSelection,
        context: NiriCalculationContext,
        result: inout LayoutResult
    ) {
        let activeIndex = projectedActiveColumnIndex(
            state: selection.state,
            columns: columns,
            in: selection.workspaceId
        )
        states[selection.workspaceId]?.accordionActiveColumnId = columns[activeIndex].column.id
        let base = accordionBaseRect(context: context)
        let axis = renderStyle.accordionAxis
        let insets = NiriAccordionGeometry.insets(
            count: columns.count,
            activeIndex: activeIndex,
            padding: renderStyle.accordionPadding,
            span: axis == .horizontal ? base.width : base.height
        )
        let containerContext = NiriContainerLayoutContext(
            frames: context.frames,
            secondaryGap: context.secondaryGap,
            time: context.time
        )
        for (index, projectedColumn) in columns.enumerated() {
            let rect = NiriAccordionGeometry.apply(insets[index], to: base, axis: axis)
                .roundedToPhysicalPixels(scale: context.area.scale)
            layoutContainer(
                container: projectedColumn.column,
                windows: projectedColumn.windows,
                placement: NiriContainerPlacement(canonicalRect: rect, renderedRect: rect, secondarySpanOverride: nil),
                context: containerContext,
                result: &result.frames
            )
            parkInactiveTabs(
                of: projectedColumn,
                visibleRect: rect,
                isFirst: index == 0,
                context: context,
                result: &result
            )
        }
    }

    func hitTestColumns(in workspaceId: WorkspaceDescriptor.ID) -> [NiriContainer] {
        let all = columns(in: workspaceId)
        guard isAccordion(in: workspaceId),
              let activeId = states[workspaceId]?.accordionActiveColumnId,
              let active = all.firstIndex(where: { $0.id == activeId })
        else { return all }
        return all.indices
            .sorted { (abs($0 - active), $0) < (abs($1 - active), $1) }
            .map { all[$0] }
    }

    private func accordionBaseRect(context: NiriCalculationContext) -> CGRect {
        let frame = context.area.workingFrame
        let gap = context.primaryGap
        switch context.orientation {
        case .horizontal:
            return CGRect(
                x: frame.minX + gap,
                y: frame.minY,
                width: max(0, frame.width - 2 * gap),
                height: frame.height
            )
        case .vertical:
            return CGRect(
                x: frame.minX,
                y: frame.minY + gap,
                width: frame.width,
                height: max(0, frame.height - 2 * gap)
            )
        }
    }
}
