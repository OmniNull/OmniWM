// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import OmniWMShellCore

extension ShellWidgetSurface {
    func prepareResourceDrag(at point: CGPoint) {
        guard visible, sliding.slot < 0, dragStart == nil, let bridge = resourceDragBridge else { return }
        let handle = element(at: point) { $0.dragItemsRef != 0 }
        guard handle != .none else { return }
        if resourceDragTracker == nil { resourceDragTracker = ShellDragOutTracker(bridge: bridge) }
        pointerGesture = nil
        resourceDragTracker?.start(dragOutAuthority(handle), at: point)
    }

    func dragResources(with event: NSEvent, at point: CGPoint) -> Bool {
        guard event.type == .leftMouseDragged, let tracker = resourceDragTracker,
              let authority = tracker.authority else { return false }
        guard visible, layout.core.contains(authority.handle),
              dragOutAuthority(authority.handle) == authority
        else { tracker.cancel()
            return false
        }
        guard let prepared = tracker.take(at: point, threshold: Self.dragThreshold) else { return true }
        let frame = CGRect(layout.core.absoluteFrame(of: authority.handle)).intersection(view.bounds)
        guard !frame.isEmpty, !frame.isNull, let image = dragOutImage(prepared) else {
            Task { await prepared.finish(false, false) }
            return true
        }
        let size = CGSize(width: min(max(frame.width, 32), 96), height: min(max(frame.height, 32), 96))
        let imageFrame = CGRect(origin: frame.origin, size: size)
        do {
            try ShellDragOutSession.start(prepared, view: view, event: event, frame: imageFrame, image: image)
            cancelInput()
        } catch {
            Log.shell.error("Drag declined: \(error)")
            Task { await prepared.finish(false, false) }
        }
        return true
    }

    func reconcileResourceDrag() {
        guard let tracker = resourceDragTracker, let authority = tracker.authority else { return }
        if !visible || !layout.core
            .contains(authority.handle) || dragOutAuthority(authority.handle) != authority { tracker.cancel() }
    }

    private func dragOutAuthority(_ handle: ElementHandle) -> ShellDragOutAuthority {
        let content = layout.core.content(of: handle)
        return ShellDragOutAuthority(
            handle: handle,
            sequence: sequence,
            declaration: content.dragItemsRef,
            action: content.dragOutAction,
            sourceID: sourceID
        )
    }

    private func dragOutImage(_ prepared: ShellDragOutPreparation) -> NSImage? {
        for entry in resourceImages.values {
            guard let binding = entry.binding, binding.request.owner == prepared.id.owner,
                  prepared.resources.contains(binding.request.resource),
                  let image = resources.resourceImages?.bitmap(binding) else { continue }
            return NSImage(cgImage: image, size: CGSize(width: 64, height: 64))
        }
        return NSImage(systemSymbolName: "doc.fill", accessibilityDescription: nil)
    }
}
