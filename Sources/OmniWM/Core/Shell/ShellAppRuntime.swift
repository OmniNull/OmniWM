// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

@MainActor
final class ShellAppRuntime {
    nonisolated static let generation = 1
    let id = UUID()
    let definition: ShellAppDefinition
    @MainActor
    final class Slot {
        let surface: ShellWidgetSurface
        var context: ShellWindowContext
        var renderedSequence = 0

        init(id: UUID, viewName: String, window: NSWindow, resources: ShellResources, folder: URL) {
            let size = window.contentRect(forFrameRect: window.frame).size
            context = ShellWindowContext(
                id: id, width: size.width, height: size.height, visible: true, viewName: viewName
            )
            surface = ShellWidgetSurface(scale: window.backingScaleFactor, resources: resources, directories: [folder])
            surface.view.autoresizingMask = [.width, .height]
            surface.view.layer?.masksToBounds = true
            window.contentView = surface.view
            surface.setRootLimit(size)
        }
    }

    let primary: Slot
    private(set) var slots: [UUID: Slot] = [:]
    var surface: ShellWidgetSurface {
        primary.surface
    }

    var context: ShellWindowContext {
        primary.context
    }

    var renderedSequence: Int {
        primary.renderedSequence
    }

    var onWindowRequest: ((ShellWindowRequest) -> String?)?
    private(set) var closed = false
    private(set) var failure: ShellScriptFailure?
    var onRender: (() -> Void)?
    var onApprovalsChange: (() -> Void)?
    private(set) var descriptors: [ShellComponentDescriptor] = []
    private(set) var networkApprovals: [ShellNetworkApproval.Key: ShellNetworkApproval] = [:] {
        didSet { if networkApprovals != oldValue { onApprovalsChange?() } }
    }

    private(set) var providerApprovals: [ShellProviderApproval.Key: ShellProviderApproval] = [:] {
        didSet { if providerApprovals != oldValue { onApprovalsChange?() } }
    }

    private let permissions: ShellNetworkPermissions
    private var text = ShellTextStore()
    private var epoch = 0
    private var mailbox: AsyncStream<ShellWidgetMessage>.Continuation?
    private var loading: Task<Void, Never>?
    private lazy var outbox = ShellWidgetOutbox { [weak self] deliveries in
        guard let self, !closed, let delivery = deliveries[definition.id],
              delivery.generation == Self.generation else { return }
        receive(delivery)
    }

    private(set) lazy var package = ShellWidgetPackage(
        name: definition.id, generation: Self.generation, outbox: outbox, permissions: permissions
    )

    init(
        definition: ShellAppDefinition,
        window: NSWindow,
        resources: ShellResources,
        permissions: ShellNetworkPermissions = ShellNetworkPermissions()
    ) {
        self.definition = definition
        self.permissions = permissions
        primary = Slot(
            id: id,
            viewName: definition.view,
            window: window,
            resources: resources,
            folder: definition.folder
        )
        attach(primary)
    }

    func addRoot(id rootID: UUID, viewName: String, window: NSWindow, resources: ShellResources) {
        guard !closed, slots[rootID] == nil else { return }
        attach(Slot(id: rootID, viewName: viewName, window: window, resources: resources, folder: definition.folder))
    }

    private func attach(_ slot: Slot) {
        let rootID = slot.context.id
        let surface = slot.surface
        slots[rootID] = slot
        surface.onAction = { [weak self, weak surface] click in
            guard let self, !closed, let surface, slots[rootID]?.surface === surface else { return }
            var event = click.event
            event.sourceID = surface.sourceID
            mailbox?.yield(.invoke(
                .window(rootID), .window, action: click.action,
                sequence: click.sequence ?? surface.sequence, event: event
            ))
        }
        mailbox?.yield(.window(slot.context))
    }

    func removeRoot(_ rootID: UUID) {
        guard let slot = slots.removeValue(forKey: rootID) else { return }
        slot.surface.onAction = nil
        slot.surface.onUnhandledEscape = nil
        slot.surface.setVisible(false)
        mailbox?.yield(.removeWindow(rootID))
    }

    func start() {
        guard loading == nil, mailbox == nil, !closed else { return }
        let source: ShellWidgetSource
        do { source = try definition.source() } catch {
            failure = ShellScriptFailure(kind: .compile, message: error.localizedDescription)
            onRender?()
            return
        }
        descriptors = source.componentDescriptors
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
            for slot in slots.values { mailbox?.yield(.window(slot.context)) }
        }
    }

    func resize(_ size: CGSize, rootID: UUID? = nil) {
        let key = rootID ?? id
        guard !closed, let slot = slots[key], size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return }
        slot.surface.setRootLimit(size)
        update(key, width: size.width, height: size.height, visible: slot.context.visible)
    }

    func setVisible(_ visible: Bool, rootID: UUID? = nil) {
        let key = rootID ?? id
        guard !closed, let slot = slots[key] else { return }
        slot.surface.setVisible(visible)
        update(key, width: slot.context.width, height: slot.context.height, visible: visible)
    }

    func close() {
        guard !closed else { return }
        closed = true
        loading?.cancel()
        loading = nil
        for key in Array(slots.keys) { removeRoot(key) }
        mailbox?.finish()
        mailbox = nil
        onRender = nil
        onApprovalsChange = nil
        onWindowRequest = nil
        ShellWidgetHost.close(package)
    }

    func receive(_ delivery: ShellWidgetDelivery) {
        guard !closed, delivery.generation == Self.generation else { return }
        recordApprovals(of: delivery)
        failure = delivery.failure
        if delivery.epoch != epoch {
            epoch = delivery.epoch
            text = ShellTextStore()
        }
        text.ingest(delivery.strings, count: delivery.stringCount)
        for (key, tree) in delivery.trees {
            guard key.view == .window, case let .window(rootID) = key.instance,
                  let slot = slots[rootID] else { continue }
            slot.surface.sequence = tree.sequence
            _ = slot.surface.apply(tree.nodes, text: text)
            slots[rootID]?.renderedSequence = tree.sequence
        }
        for request in delivery.windowRequests where package.services.contains(request.id) {
            let error: String?
            if slots[request.rootID]?.surface.sourceID == request.sourceID, let onWindowRequest {
                error = onWindowRequest(request)
            } else {
                error = "The owning app window is no longer available."
            }
            package.services.complete(ShellWindowRequest.completion(id: request.id, error: error))
        }
        onRender?()
    }

    func permissionsChanged() {
        guard !closed else { return }
        networkApprovals = networkApprovals.filter { permissions.isPending($0.key) }
        providerApprovals = providerApprovals.filter { permissions.decide($0.value) == .notApproved }
        package.permissionsChanged()
    }

    private func recordApprovals(of delivery: ShellWidgetDelivery) {
        for approval in delivery.networkApprovals where permissions.isPending(approval.key) {
            networkApprovals[approval.key] = approval
        }
        for approval in delivery.providerApprovals where permissions.decide(approval) == .notApproved {
            providerApprovals[approval.key] = approval
        }
    }

    private func update(_ rootID: UUID, width: Double, height: Double, visible: Bool) {
        guard let previous = slots[rootID]?.context else { return }
        let next = ShellWindowContext(
            id: rootID, width: width, height: height, visible: visible, viewName: previous.viewName
        )
        guard next != previous else { return }
        slots[rootID]?.context = next
        mailbox?.yield(.window(next))
    }
}
