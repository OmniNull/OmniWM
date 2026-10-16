// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import OmniWMShellCore

struct ShellDragOutAuthority: Equatable, Sendable {
    let handle: ElementHandle
    let sequence: Int
    let declaration: UInt32
    let action: UInt32
    let sourceID: UInt64

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.handle == rhs.handle && lhs.declaration == rhs.declaration && lhs.action == rhs.action && lhs
            .sourceID == rhs.sourceID
    }
}

struct ShellDragOutPreparation: Sendable {
    let id: ShellServiceID
    let authority: ShellDragOutAuthority
    let resources: [ShellResourceID]
    let pin: ShellResourceStore.Pin
    let operation: ShellResourceOperation
    let begin: @Sendable () async -> Void
    let finish: @Sendable (Bool, Bool) async -> Void
}

struct ShellDragOutBridge: Sendable {
    let prepare: @Sendable (ShellDragOutAuthority) async throws -> ShellDragOutPreparation
}

@MainActor
final class ShellDragOutTracker {
    private let bridge: ShellDragOutBridge
    private let report: @MainActor (String) -> Void
    private var request = UUID()
    private var point = CGPoint.zero
    private(set) var authority: ShellDragOutAuthority?
    private(set) var ready: ShellDragOutPreparation?
    private(set) var preparation: Task<Void, Never>?

    init(
        bridge: ShellDragOutBridge,
        report: @escaping @MainActor (String) -> Void = { Log.shell.error("Drag declined: \($0)") }
    ) {
        self.bridge = bridge
        self.report = report
    }

    isolated deinit {
        if let ready { Task { await ready.finish(false, false) } }
    }

    func start(_ authority: ShellDragOutAuthority, at point: CGPoint) {
        cancel()
        self.authority = authority
        self.point = point
        let request = request
        let bridge = bridge
        preparation = Task { [weak self] in
            do {
                let prepared = try await bridge.prepare(authority)
                guard let self, self.request == request, self.authority == authority, prepared.authority == authority,
                      prepared.operation.isActive
                else {
                    await prepared.finish(false, false)
                    return
                }
                ready = prepared
            } catch {
                guard let self, self.request == request else { return }
                self.authority = nil
                report(String(describing: error))
            }
        }
    }

    func take(at point: CGPoint, threshold: CGFloat) -> ShellDragOutPreparation? {
        guard let ready else { return nil }
        guard ready.operation.isActive else { cancel()
            return nil
        }
        guard hypot(point.x - self.point.x, point.y - self.point.y) >= threshold else { return nil }
        self.ready = nil
        authority = nil
        preparation = nil
        request = UUID()
        return ready
    }

    func cancel() {
        request = UUID()
        authority = nil
        preparation = nil
        if let ready {
            self.ready = nil
            Task { await ready.finish(false, false) }
        }
    }
}

@MainActor
final class ShellDragOutSession: NSObject, NSDraggingSource {
    private enum Event { case began, ended(Bool) }
    private static var active: ShellDragOutSession?
    private let events: AsyncStream<Event>.Continuation
    private var session: NSDraggingSession?
    private var began = false
    private var ended = false
    private(set) var completion: Task<Void, Never>?

    init(prepared: ShellDragOutPreparation) {
        let pair = AsyncStream<Event>.makeStream(bufferingPolicy: .bufferingOldest(2))
        events = pair.continuation
        super.init()
        completion = Task { @MainActor [self] in
            var copied = false
            for await event in pair.stream {
                switch event {
                case .began: await prepared.begin()
                case let .ended(value): copied = value
                }
            }
            await prepared.finish(copied, true)
            if Self.active === self { Self.active = nil }
            completion = nil
        }
    }

    static func start(
        _ prepared: ShellDragOutPreparation,
        view: NSView,
        event: NSEvent,
        frame: CGRect,
        image: NSImage
    ) throws {
        guard active == nil, prepared.operation.isActive, event.type == .leftMouseDragged,
              let window = view.window, event.window === window, window.isVisible, !frame.isEmpty
        else {
            throw ShellResourceFailure("drag_source_unavailable")
        }
        let items = prepared.pin.values.enumerated().map { index, value in
            let writer: any NSPasteboardWriting
            switch value {
            case let .file(url),
                 let .url(url): writer = url as NSURL
            case let .text(text): writer = text as NSString
            }
            let item = NSDraggingItem(pasteboardWriter: writer)
            item.setDraggingFrame(
                frame.offsetBy(dx: CGFloat(index % 4) * 3, dy: CGFloat(index % 4) * 3),
                contents: image
            )
            return item
        }
        guard !items.isEmpty,
              items.count <= ShellResourceStore.attachmentLimit else { throw ShellResourceFailure("invalid_resources") }
        let source = ShellDragOutSession(prepared: prepared)
        active = source
        source.session = view.beginDraggingSession(with: items, event: event, source: source)
        source.session?.draggingFormation = .pile
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        begin()
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        end(copied: operation.contains(.copy))
    }

    func begin() {
        guard !began, !ended else { return }
        began = true
        events.yield(.began)
    }

    func end(copied: Bool) {
        guard !ended else { return }
        ended = true
        self.session = nil
        events.yield(.ended(copied))
        events.finish()
    }
}
