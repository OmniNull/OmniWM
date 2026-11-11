// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import OmniWMScriptHost
import OmniWMShellCore

@MainActor
final class CommandPaletteShellPresenter {
    static let queryKey = "query"
    static let resultsKey = "results"
    static let commandPrefix = "palette "
    static let beforeKey = ShellWidgetLayout.elementKey("results-before")
    static let afterKey = ShellWidgetLayout.elementKey("results-after")
    static let resultsElement = ShellWidgetLayout.elementKey(resultsKey)

    let config: ShellConfig
    let fingerprint: [String: SettingsFileAccess.Fingerprint]
    let surface: ShellWidgetSurface
    let chrome: ShellChromeView
    private let fieldFrame: CGRect
    private(set) lazy var field = surface.pinTextInput(key: Self.queryKey, frame: fieldFrame) { [weak self] event in
        self?.receiveText(event)
    }

    var onQuery: (@MainActor (String) -> Void)?
    var onCommand: (@MainActor (String) -> Void)?
    var onMenu: (@MainActor (String, ShellAnchor) -> Void)?
    var onFailure: (@MainActor () -> Void)?
    var onProblem: (@MainActor (ShellScriptFailure) -> Void)?
    var onTree: (@MainActor () -> Void)?
    var onWindowChange: (@MainActor () -> Void)?
    private(set) var rowWindow = CommandPaletteRowWindow()
    private var applying = false
    private var windowChanged = false
    private var revealRequest = 0
    private var revealedRequest: Int?

    private let key = ShellBarKey(monitor: .fallback)
    private let onNetworkApprovals: ([ShellNetworkApproval]) -> Void
    private let onProviderApprovals: ([ShellProviderApproval]) -> Void
    private var text = ShellTextStore()
    private var epoch: Int?
    private var mailbox: AsyncStream<ShellWidgetMessage>.Continuation?
    private var worker: Task<Void, Never>?
    private var package: ShellWidgetPackage?
    private(set) var published: ShellCommandPaletteData?
    private var reportedQuery = ""
    private var closed = false
    private(set) var hasTree = false
    private var lastNodes: [UInt8] = []
    private var lastSequence = 0
    private var drawn: ShellCommandPaletteData?
    private(set) var fallback: Bool
    private let bundled: @MainActor () -> ShellCommandPaletteSource?
    private var outbox: ShellWidgetOutbox?
    private var generation = 0
    private var failures = 0
    let bitmapPrefix = "palette/" + UUID().uuidString + "/"
    var bitmaps: Set<String> = []

    var bitmapGeneration: Int {
        generation
    }

    init(
        source: ShellCommandPaletteSource,
        scale: CGFloat,
        fieldFrame: CGRect,
        onNetworkApprovals: @escaping ([ShellNetworkApproval]) -> Void = { _ in },
        onProviderApprovals: @escaping ([ShellProviderApproval]) -> Void = { _ in },
        bundled: @escaping @MainActor () -> ShellCommandPaletteSource?
    ) {
        config = source.config
        fingerprint = source.fingerprint
        fallback = source.bundled
        self.bundled = bundled
        self.onNetworkApprovals = onNetworkApprovals
        self.onProviderApprovals = onProviderApprovals
        self.fieldFrame = fieldFrame
        surface = ShellWidgetSurface(scale: scale, resources: source.resources, directories: source.directories)
        chrome = ShellChromeView(content: surface.view)
        _ = field
        surface.onAction = { [weak self] click in
            guard let self, !closed else { return }
            perform(click)
        }
        surface.onMove = { [weak self] in
            self?.scrolled()
        }
        surface.onMenu = { [weak self] event in
            guard let self, !closed else { return }
            onMenu?(text.string(event.target), event.anchor)
        }
        outbox = ShellWidgetOutbox { [weak self] batch in
            self?.receive(batch)
        }
        start(source)
    }

    isolated deinit {
        close()
    }

    func publish(_ data: ShellCommandPaletteData, reveal request: Int? = nil) {
        if let request { revealRequest = request }
        guard !closed, data != published else { return }
        if let previous = published?.preview?.image, previous != data.preview?.image { removeBitmap(previous) }
        published = data
        if !data.open { retireBitmaps() }
        if data.query != reportedQuery, !field.hasMarkedText {
            field.setText(data.query)
            reportedQuery = data.query
        }
        var widgetData = ShellWidgetData()
        widgetData.commandPalette = data
        mailbox?.yield(.update(widgetData))
    }

    func resize(to size: CGSize) {
        surface.setRootLimit(size)
    }

    func beginSession() {
        rowWindow.reset()
        revealedRequest = nil
    }

    func revealPending(for request: Int) -> Bool {
        revealedRequest != request
    }

    func slice(ids: [String], selected: Int?, limit: Float) -> CommandPaletteRowWindow.Slice {
        rowWindow.slice(ids: ids, selected: selected, limit: limit)
    }

    func setVisible(_ visible: Bool) {
        surface.setVisible(visible)
    }

    func close() {
        guard !closed else { return }
        closed = true
        retireBitmaps()
        retirePackage()
        surface.onAction = nil
        chrome.removeFromSuperview()
    }

    private func start(_ source: ShellCommandPaletteSource) {
        guard let outbox else { return }
        let package = ShellWidgetPackage(
            name: ShellWidgetHost.commandPaletteWidget,
            generation: generation,
            outbox: outbox,
            permissions: source.permissions,
            retireResourceImages: { [images = source.resources.resourceImages] owner in await images?.retire(owner) }
        )
        self.package = package
        let mailbox = startWorker(package, source: source.source, generation: generation)
        mailbox.yield(.bars([key: ShellBarData()]))
        mailbox.yield(.popout(key, true))
        if let published {
            var widgetData = ShellWidgetData()
            widgetData.commandPalette = published
            mailbox.yield(.update(widgetData))
        }
    }

    private func retirePackage() {
        ShellWidgetHost.retireTraceCapture(package)
        mailbox?.finish()
        mailbox = nil
        worker?.cancel()
        worker = nil
        ShellWidgetHost.close(package)
        package = nil
    }

    private func startWorker(
        _ package: ShellWidgetPackage, source: ShellWidgetSource, generation: Int
    ) -> AsyncStream<ShellWidgetMessage>.Continuation {
        let retiring = Array(ShellWidgetHost.retiringTasks.values)
        let (messages, mailbox) = AsyncStream.makeStream(of: ShellWidgetMessage.self)
        package.capture.attach(mailbox)
        ShellWidgetHost.joinTraceCapture(package)
        package.services.attachWake { mailbox.yield(.services) }
        package.providerInbox.attachWake { mailbox.yield(.providers) }
        package.resourceInbox.attachWake { mailbox.yield(.resources) }
        self.mailbox = mailbox
        worker = Task.detached(priority: .userInitiated) { [weak self] in
            for task in retiring { await task.value }
            guard !Task.isCancelled else { await package.close()
                return
            }
            if let failure = await package.load(source) {
                await self?.loadFailed(failure, generation: generation)
            } else {
                for await message in messages {
                    guard !Task.isCancelled else { break }
                    await package.receive(message)
                }
            }
            await package.close()
        }
        return mailbox
    }

    private func receiveText(_ event: ShellEvent) {
        guard !closed, event.kind == .textChange, let query = event.text else { return }
        reportedQuery = query
        onQuery?(query)
    }

    private func perform(_ click: ShellClick) {
        guard click.action & OMNI_ACTION_HANDLER != 0 else {
            performCommand(click)
            return
        }
        var event = click.event
        let id = ShellInvocation.next()
        event.invocationID = id
        event.sourceID = surface.sourceID
        if let token = event.trackingToken { surface.bindGestureInvocation(trackToken: token, invocationID: id) }
        var enqueued = false
        defer { if !enqueued { surface.acknowledgeGesture(through: id) } }
        guard let package, let mailbox else { return }
        let sequence = click.sequence ?? surface.sequence
        if event.isGesture {
            let gesture = ShellGestureBox.Gesture(
                bar: key, view: .popout, action: click.action, sequence: sequence, event: event
            )
            if let pending = package.gestures.post(gesture) {
                if case .enqueued = mailbox.yield(.gesture(pending)) { enqueued = true }
            } else { enqueued = true }
        } else {
            package.gestures.seal()
            if case .enqueued = mailbox.yield(.invoke(
                key, .popout, action: click.action, sequence: sequence, event: event
            )) {
                enqueued = true
            }
        }
    }

    private func performCommand(_ click: ShellClick) {
        let command = text.string(click.action)
        guard command.hasPrefix(Self.commandPrefix) else { return }
        let action = command.dropFirst(Self.commandPrefix.count)
        if applying, click.event.kind == .hover, click.event.phase == .began, action.hasPrefix("highlight ") {
            return
        }
        if action.hasPrefix("menu ") {
            onMenu?(String(action.dropFirst("menu ".count)), click.anchor)
        } else if click.event.kind != .hover || click.event.phase == .began {
            onCommand?(String(action))
        }
    }

    private func receive(_ batch: [String: ShellWidgetDelivery]) {
        guard !closed, let delivery = batch[ShellWidgetHost.commandPaletteWidget],
              delivery.generation == generation
        else { return }
        if !delivery.networkApprovals.isEmpty { onNetworkApprovals(delivery.networkApprovals) }
        if !delivery.providerApprovals.isEmpty { onProviderApprovals(delivery.providerApprovals) }
        let treeKey = ShellTreeKey(bar: key, view: .popout)
        let acknowledgement = delivery.acknowledgements[treeKey]?.invocationID ?? 0
        if let failure = delivery.failure { onProblem?(failure) }
        guard let tree = delivery.trees[treeKey] else {
            surface.acknowledgeGesture(through: acknowledgement)
            if delivery.failure != nil { countFailure(delivery.failure) }
            return
        }
        let anchor = visibleAnchor()
        applying = true
        drawn = nil
        let inputs = epoch != delivery.epoch ? surface.readOnlyInputStates() : []
        if epoch != delivery.epoch {
            epoch = delivery.epoch
            text = ShellTextStore()
            surface.reset(text: text)
        }
        text.ingest(delivery.strings, count: delivery.stringCount)
        surface.sequence = tree.sequence
        guard surface.apply(tree.nodes, text: text, gestureAcknowledgement: acknowledgement, keeping: anchor) else {
            applying = false
            countFailure(nil)
            return
        }
        if delivery.failure == nil { failures = 0 }
        surface.restoreReadOnlyInputStates(inputs)
        lastNodes = tree.nodes
        lastSequence = tree.sequence
        applied()
    }

    private func applied() {
        hasTree = true
        let current = drawsPublishedList()
        drawn = current ? published : nil
        windowChanged = recordViewport() || windowChanged
        if current {
            windowChanged = measureRows() || windowChanged
            revealIfRequested()
        }
        applying = false
        if windowChanged {
            windowChanged = false
            onWindowChange?()
        }
        restoreQueryFocusIfNeeded()
        onTree?()
    }

    private func fail() {
        guard !closed else { return }
        Log.shell.error("The command palette widget failed; closing the palette")
        close()
        onFailure?()
    }
}

extension CommandPaletteShellPresenter {
    private func loadFailed(_ failure: ShellScriptFailure, generation: Int) {
        guard !closed, generation == self.generation else { return }
        onProblem?(failure)
        fallBack(failure)
    }

    private func countFailure(_ failure: ShellScriptFailure?) {
        failures += 1
        if failures >= ShellWidgetHost.failureLimit { fallBack(failure) }
    }

    private func fallBack(_ failure: ShellScriptFailure?) {
        guard !fallback, let source = bundled() else {
            fail()
            return
        }
        let reason = failure?.localizedDescription ?? "its tree could not be applied"
        Log.shell.error("The command palette style failed (\(reason)); using the bundled palette")
        fallback = true
        retireBitmaps()
        surface.cancelInput()
        retirePackage()
        generation += 1
        failures = 0
        epoch = nil
        onWindowChange?()
        start(source)
    }

    private func visibleAnchor() -> ShellScrollAnchor? {
        guard let container = surface.layout.handle(forKey: Self.resultsKey) else { return nil }
        let row = firstVisibleRow(in: container)
        return ShellScrollAnchor(
            container: Self.resultsElement,
            item: row?.key,
            top: row?.top ?? 0,
            offset: surface.layout.core.scrollOffset(of: container)
        )
    }

    private struct VisibleRow {
        let index: Int
        let key: UInt64
        let top: Float
    }

    private func firstVisibleRow(in container: ElementHandle) -> VisibleRow? {
        let offset = surface.layout.core.scrollOffset(of: container)
        var index = 0
        var found: VisibleRow?
        surface.layout.core.forEachChild(of: container) { child, key in
            guard found == nil, key != Self.beforeKey, key != Self.afterKey else { return }
            let frame = surface.layout.core.layoutFrame(of: child)
            if frame.y + frame.height > offset { found = VisibleRow(index: index, key: key, top: frame.y - offset) }
            index += 1
        }
        return found
    }

    private func revealIfRequested() {
        guard revealedRequest != revealRequest, let selected = published?.selected else { return }
        if !selected.isEmpty {
            surface.reveal(key: selected, within: Self.resultsKey)
        }
        revealedRequest = revealRequest
    }

    private func scrolled() {
        guard !closed, recordViewport(), !coversViewport() else { return }
        if applying {
            windowChanged = true
        } else {
            onWindowChange?()
        }
    }

    private func coversViewport() -> Bool {
        guard let published, rowWindow.viewport > 0 else { return false }
        let view = rowWindow.viewport
        var bottom = Float(published.before)
        for row in published.rows {
            bottom += rowWindow.advance(of: row.id)
        }
        let coversTop = published.first == 0 || Float(published.before) <= max(rowWindow.offset - view / 2, 0)
        let coversBottom = published.first + published.rows.count >= published.total
            || bottom >= rowWindow.offset + view * 3 / 2
        return coversTop && coversBottom
    }

    private func recordViewport() -> Bool {
        guard let container = surface.layout.handle(forKey: Self.resultsKey) else { return false }
        let viewport = rowWindow.record(
            viewport: surface.layout.core.layoutFrame(of: container).height,
            offset: surface.layout.core.scrollOffset(of: container),
            gap: surface.layout.core.layoutStyle(of: container).gap
        )
        var id: String?
        var top: Float = 0
        if let rows = drawn?.rows, let row = firstVisibleRow(in: container), row.index < rows.count {
            id = rows[row.index].id
            top = row.top
        }
        let anchor = rowWindow.record(anchor: id, top: top)
        return viewport || anchor
    }

    private func measureRows() -> Bool {
        guard let rows = published?.rows, let container = surface.layout.handle(forKey: Self.resultsKey) else {
            return false
        }
        let gap = surface.layout.core.layoutStyle(of: container).gap
        var changed = false
        var index = 0
        surface.layout.core.forEachChild(of: container) { child, key in
            guard key != Self.beforeKey, key != Self.afterKey else { return }
            let height = surface.layout.core.layoutFrame(of: child).height
            changed = rowWindow.record(advance: height + gap, for: rows[index].id) || changed
            index += 1
        }
        return changed
    }
}

extension CommandPaletteShellPresenter {
    func redraw() {
        guard !closed, !lastNodes.isEmpty else { return }
        let anchor = visibleAnchor()
        let inputs = surface.readOnlyInputStates()
        applying = true
        drawn = nil
        surface.reset(text: text)
        surface.sequence = lastSequence
        guard surface.apply(lastNodes, text: text, keeping: anchor) else {
            fail()
            return
        }
        surface.restoreReadOnlyInputStates(inputs)
        applied()
    }
}
