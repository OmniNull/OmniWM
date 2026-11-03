// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

@MainActor
final class ShellAppWindowSession {
    nonisolated static let generation = 1
    let id = UUID()
    let definition: ShellAppDefinition
    let surface: ShellWidgetSurface
    private(set) var context: ShellWindowContext
    private(set) var closed = false
    private(set) var failure: ShellScriptFailure?
    private(set) var renderedSequence = 0
    var onRender: (() -> Void)?
    private var text = ShellTextStore()
    private var epoch = 0
    private var mailbox: AsyncStream<ShellWidgetMessage>.Continuation?
    private var loading: Task<Void, Never>?
    private lazy var outbox = ShellWidgetOutbox { [weak self] deliveries in
        guard let self, !closed, let delivery = deliveries[definition.id],
              delivery.generation == Self.generation else { return }
        receive(delivery)
    }

    private(set) lazy var package = ShellWidgetPackage(name: definition.id, generation: Self.generation, outbox: outbox)

    init(definition: ShellAppDefinition, window: NSWindow, resources: ShellResources) {
        self.definition = definition
        let size = window.contentRect(forFrameRect: window.frame).size
        context = ShellWindowContext(id: id, width: size.width, height: size.height, visible: true)
        surface = ShellWidgetSurface(
            scale: window.backingScaleFactor, resources: resources, directories: [definition.folder]
        )
        surface.view.autoresizingMask = [.width, .height]
        surface.view.layer?.masksToBounds = true
        window.contentView = surface.view
        surface.setRootLimit(size)
        surface.onAction = { [weak self] click in
            guard let self, !closed else { return }
            mailbox?.yield(.invoke(
                .window(id), .window, action: click.action,
                sequence: click.sequence ?? surface.sequence, event: click.event
            ))
        }
    }

    func start() {
        guard loading == nil, mailbox == nil, !closed else { return }
        let source: ShellWidgetSource
        do { source = try definition.source() } catch {
            failure = ShellScriptFailure(kind: .compile, message: error.localizedDescription)
            onRender?()
            return
        }
        let package = package
        loading = Task { [weak self] in
            let failure = await package.load(source)
            guard let self, !closed else { await package.close()
                return
            }
            loading = nil
            if let failure {
                self.failure = failure
                onRender?()
                return
            }
            mailbox = ShellWidgetHost.connect(package)
            mailbox?.yield(.window(context))
        }
    }

    func resize(_ size: CGSize) {
        guard !closed, size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
        surface.setRootLimit(size)
        update(width: size.width, height: size.height, visible: context.visible)
    }

    func setVisible(_ visible: Bool) {
        guard !closed else { return }
        surface.setVisible(visible)
        update(width: context.width, height: context.height, visible: visible)
    }

    func close() {
        guard !closed else { return }
        closed = true
        loading?.cancel()
        loading = nil
        surface.onAction = nil
        surface.setVisible(false)
        mailbox?.finish()
        mailbox = nil
        onRender = nil
        ShellWidgetHost.close(package)
    }

    func receive(_ delivery: ShellWidgetDelivery) {
        guard !closed, delivery.generation == Self.generation else { return }
        failure = delivery.failure
        if delivery.epoch != epoch {
            epoch = delivery.epoch
            text = ShellTextStore()
        }
        text.ingest(delivery.strings, count: delivery.stringCount)
        let key = ShellTreeKey(instance: .window(id), view: .window)
        if let tree = delivery.trees[key] {
            surface.sequence = tree.sequence
            _ = surface.apply(tree.nodes, text: text)
            renderedSequence = tree.sequence
        }
        onRender?()
    }

    private func update(width: Double, height: Double, visible: Bool) {
        let next = ShellWindowContext(id: id, width: width, height: height, visible: visible)
        guard next != context else { return }
        context = next
        mailbox?.yield(.window(next))
    }
}
