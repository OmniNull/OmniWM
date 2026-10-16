// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import OmniWMShellCore

extension ShellWidgetSurface {
    func updateResourceDropRegistration(_ enabled: Bool) {
        guard hasResourceDrops != enabled else { return }
        hasResourceDrops = enabled
        if enabled { view.registerForDraggedTypes(ShellDropSnapshot.registeredTypes) }
        else { view.unregisterDraggedTypes()
            cancelResourceDrop()
        }
        onResourceDropRegistrationChange?()
    }

    func draggingResource(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let pasteboard = sender.draggingPasteboard
        if dropSequence != sender.draggingSequenceNumber || dropPasteboardChange != pasteboard.changeCount {
            dropSequence = sender.draggingSequenceNumber
            dropPasteboardChange = pasteboard.changeCount
            dropOffered = ShellDropSnapshot.types(pasteboard)
        }
        return updateResourceDrop(
            at: view.convert(sender.draggingLocation, from: nil),
            types: dropOffered,
            canCopy: sender.draggingSourceOperationMask.contains(.copy)
        )
    }

    func updateResourceDrop(at point: CGPoint, types: ShellDropTypes, canCopy: Bool = true) -> NSDragOperation {
        dropPoint = point
        dropOffered = types
        dropCanCopy = canCopy
        let handle = visible && hasResourceDrops && canCopy ? element(at: point, matching: {
            $0
                .resourceAccepts & UInt32(types.rawValue) != 0 &&
                ($0.resourceDropAction != 0 || $0.resourceHoverAction != 0)
        }) : .none
        let next = handle == .none ? nil : capture(handle)
        let changed = next?.handle != dropTarget?.handle || next?.content.resourceHoverAction != dropTarget?.content
            .resourceHoverAction || dropHoverTypes != types
        if changed {
            emitResourceHover(.exited)
            dropTarget = next
            dropHoverTypes = types
            emitResourceHover(.entered)
        } else { dropTarget = next }
        if dropPreflight == nil, let resourceDropBridge {
            dropPreflight = ShellDropPreflight(bridge: resourceDropBridge) { [weak self] error in
                self?.onResourceDropDeclined?(error)
            }
        }
        let authority = next.flatMap(dropAuthority)
        dropPreflight?.update(authority)
        return authority != nil && dropPreflight?.reservation != nil ? .copy : []
    }

    func reconcileResourceDrop() {
        guard let point = dropPoint else { return }
        _ = updateResourceDrop(at: point, types: dropOffered, canCopy: dropCanCopy)
    }

    func performResourceDrop(_ sender: any NSDraggingInfo) -> Bool {
        defer { onResourceDragEnd?() }
        guard draggingResource(sender).contains(.copy), let target = dropTarget,
              let authority = dropAuthority(target), let perform = onResourceDrop,
              let bridge = resourceDropBridge else { return false }
        let snapshot: ShellDropSnapshot
        do { snapshot = try ShellDropSnapshot.capture(
            sender.draggingPasteboard,
            accepts: ShellDropTypes(rawValue: authority.accepts)
        ) } catch {
            onResourceDropDeclined?(String(String(describing: error).prefix(1024)))
            cancelResourceDrop()
            return false
        }
        guard let reservation = dropPreflight?.take(authority) else { return false }
        let point = view.convert(sender.draggingLocation, from: nil)
        let local = CGPoint(x: point.x - target.origin.x, y: point.y - target.origin.y)
        cancelResourceDrop()
        perform(reservation, snapshot, local, bridge.finish)
        return true
    }

    func cancelResourceDrop() {
        dropPreflight?.clear()
        emitResourceHover(.exited)
        dropTarget = nil
        dropPoint = nil
        dropOffered = []
        dropHoverTypes = []
        dropPasteboardChange = nil
        dropSequence = nil
    }

    private func dropAuthority(_ capture: ShellPointerCapture) -> ShellDropAuthority? {
        guard capture.content.resourceDropAction != 0 else { return nil }
        return ShellDropAuthority(
            handle: capture.handle,
            sequence: capture.sequence,
            action: capture.content.resourceDropAction,
            accepts: UInt8(truncatingIfNeeded: capture.content.resourceAccepts),
            sourceID: sourceID
        )
    }

    private func emitResourceHover(_ phase: ShellEvent.Phase) {
        guard let target = dropTarget, target.content.resourceHoverAction != 0 else { return }
        var event = ShellEvent(button: .none)
        event.kind = .dropHover
        event.phase = phase
        event.dropTypes = dropHoverTypes.rawValue
        emit(target.content.resourceHoverAction, capture: target, point: dropPoint ?? target.origin, event: event)
    }
}
