// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMScriptHost

struct ConfigScriptBarScratch {
    fileprivate var tiled: [WindowToken] = []
    fileprivate var floating: [WindowToken] = []
    fileprivate var placed: Set<WindowToken> = []
    fileprivate var hiddenTail: [WindowToken] = []
    fileprivate var columnTokens: [WindowToken] = []
    fileprivate var pills = ScriptBarPillScratch()

    fileprivate mutating func appendTokens(of windows: [NiriWindow]) {
        windows.withUnsafeBufferPointer { nodes in
            for tile in nodes.indices {
                columnTokens.append(nodes[tile].token)
            }
        }
    }
}

private struct ScriptBarPillScratch {
    var grouping = WorkspaceBarPillGrouping()
    var order: [Int] = []
    var names: [String] = []
}

private struct ScriptBarContext {
    let session: ConfigScriptSession
    let options: WorkspaceBarProjectionOptions
    let focused: WindowToken?
    let hidden: Set<pid_t>
    let manager: WorkspaceManager
    let windows: WindowModel.ReadView
    let cache: AppInfoCache
    let niri: NiriLayoutEngine?
}

@MainActor
private struct ScriptBarPillSource: WorkspaceBarPillSource {
    let tokens: UnsafeBufferPointer<WindowToken>
    let windows: WindowModel.ReadView
    let cache: AppInfoCache
    let focused: WindowToken?
    let hidden: Set<pid_t>

    func key(of member: Int) -> WorkspaceBarAppKey {
        let token = tokens[member]
        let key = windows.withEntry(token) { entry -> WorkspaceBarAppKey? in
            if let hosted = entry.target.hostedMetadata { return .hosted(appId: hosted.appId) }
            if let replacement = entry.managedReplacementMetadata?.bundleId,
               let key = WorkspaceBarAppKey.bundle(replacement)
            {
                return key
            }
            return cache.withCachedBundleId(for: token.pid) { $0 != nil ? WorkspaceBarAppKey.bundle($0!) : nil }
        }
        return (key ?? nil) ?? .process(token.pid)
    }

    func isSameApp(_ member: Int, as first: Int) -> Bool {
        let token = tokens[member]
        let firstToken = tokens[first]
        if token.pid == firstToken.pid, isPlainProcessWindow(token), isPlainProcessWindow(firstToken) { return true }
        let entryIdentity = identity(of: token)
        let firstIdentity = identity(of: firstToken)
        if let hosted = entryIdentity.hostedAppId { return firstIdentity.hostedAppId == hosted }
        if token.pid == firstToken.pid, entryIdentity.replacement == nil,
           firstIdentity.replacement == nil { return true }
        guard let bundle = entryIdentity.replacement ?? cache.cachedBundleId(for: token.pid) else { return true }
        return cache.withCachedBundleId(for: firstToken.pid) { cached in
            guard let other = firstIdentity.replacement ?? cached else { return true }
            return WorkspaceBarAppKey.sameBundle(bundle, other)
        }
    }

    func isHidden(_ member: Int) -> Bool {
        hidden.contains(tokens[member].pid)
    }

    func isFocused(_ member: Int) -> Bool {
        tokens[member] == focused
    }

    private func isPlainProcessWindow(_ token: WindowToken) -> Bool {
        windows.withEntry(token) { entry in
            if case .hosted = entry.target { return false }
            return entry.managedReplacementMetadata == nil
        } ?? false
    }

    private func identity(of token: WindowToken) -> (hostedAppId: String?, replacement: String?) {
        windows.withEntry(token) { entry in
            (entry.target.hostedMetadata?.appId, entry.managedReplacementMetadata?.bundleId)
        } ?? (nil, nil)
    }
}

extension WMController {
    func appendScriptWorkspaceBar(
        session: ConfigScriptSession, to output: inout ConfigScriptSnapshotWriter, scratch: inout ConfigScriptBarScratch
    ) {
        let manager = workspaceManager
        let interaction = manager.interactionMonitorId?.scriptIdentifier
        guard output.row({ $0.flag(UInt8(OMNI_CONFIG_BAR_ROW_HEADER)) && $0.string(interaction) }) else { return }
        let workspacesByMonitor = manager.workspaceIdsByMonitor()
        for monitor in manager.monitors {
            let resolved = settings.workspaceBar.resolved(for: monitor)
            let context = ScriptBarContext(
                session: session, options: resolved.projectionOptions,
                focused: manager.selectedManagedToken, hidden: manager.hiddenAppPIDs,
                manager: manager, windows: manager.windowQueries, cache: appInfoCache, niri: manager.niriEngine
            )
            guard appendScriptBarDisplay(monitor, resolved: resolved, to: &output),
                  appendScriptBarScratchpads(context, to: &output, scratch: &scratch)
            else { return }
            let active = manager.activeWorkspace(on: monitor.id)?.id
            for workspaceId in workspacesByMonitor[monitor.id] ?? [] {
                guard let workspace = manager.descriptor(for: workspaceId) else { continue }
                guard appendScriptBarWorkspace(workspace, active: active, context, to: &output, scratch: &scratch)
                else { return }
            }
        }
    }

    private func appendScriptBarDisplay(
        _ monitor: Monitor, resolved: ResolvedBarSettings, to output: inout ConfigScriptSnapshotWriter
    ) -> Bool {
        let visible = (workspaceBarManager.shownBarFrames[monitor.id]?.count ?? 0) > 0
        let height = WorkspaceBarGeometry.resolve(monitor: monitor, resolved: resolved, isVisible: visible).barHeight
        let flags = (resolved.enabled ? OMNI_CONFIG_BAR_ENABLED : 0) | (visible ? OMNI_CONFIG_BAR_VISIBLE : 0)
            | (resolved.showLabels ? OMNI_CONFIG_BAR_LABELS : 0)
        return output.row { row in
            row.flag(UInt8(OMNI_CONFIG_BAR_ROW_DISPLAY)) && row.string(monitor.id.scriptIdentifier)
                && row.string(monitor.name) && row.flag(UInt8(flags))
                && row.detailNumber(CGFloat(resolved.backgroundOpacity)) && row.detailNumber(height)
        }
    }

    private func appendScriptBarScratchpads(
        _ context: ScriptBarContext, to output: inout ConfigScriptSnapshotWriter,
        scratch: inout ConfigScriptBarScratch
    ) -> Bool {
        let manager = context.manager
        let windows = context.windows
        for rawValue in ScratchpadIndex.range {
            guard let index = ScratchpadIndex(rawValue) else { continue }
            scratch.tiled.removeAll(keepingCapacity: true)
            for token in manager.scratchpadMembers(in: index)
                where windows.withEntry(token, { _ in true }) == true && !isScriptBarExcluded(token, context)
            {
                scratch.tiled.append(token)
            }
            guard !scratch.tiled.isEmpty else { continue }
            let revealed = manager.revealedScratchpadIndex() == index
            let visible = revealed && scratch.tiled.contains { token in
                manager.hiddenState(for: token) == nil && !manager.isAppHidden(pid: token.pid)
            }
            guard output.row({ row in
                row.flag(UInt8(OMNI_CONFIG_BAR_ROW_SCRATCHPAD)) && row.detailValue(UInt16(truncatingIfNeeded: rawValue))
                    && row.string(settings.scratchpadLabel(for: rawValue))
                    && row.flag(visible ? UInt8(OMNI_CONFIG_BAR_VISIBLE) : 0)
            }) else { return false }
            let stored = scratch.tiled.withUnsafeBufferPointer { members in
                appendScriptBarPills(
                    members,
                    .byApp(keepsLayoutOrder: false),
                    context,
                    to: &output,
                    scratch: &scratch.pills
                )
            }
            guard stored else { return false }
        }
        return true
    }

    private func appendScriptBarWorkspace(
        _ workspace: WorkspaceDescriptor, active: WorkspaceDescriptor.ID?, _ context: ScriptBarContext,
        to output: inout ConfigScriptSnapshotWriter, scratch: inout ConfigScriptBarScratch
    ) -> Bool {
        let hasColumns = collectScriptBarMembers(in: workspace, context, scratch: &scratch)
        let isActive = workspace.id == active
        if context.options.hideEmptyWorkspaces, scratch.tiled.isEmpty, scratch.floating.isEmpty, !isActive {
            return true
        }
        guard output.row({ row in
            row.flag(UInt8(OMNI_CONFIG_BAR_ROW_WORKSPACE)) && row.string(workspace.id) && row.string(workspace.name)
                && row.string(settings.workspaces.configScriptDisplayName(for: workspace.name))
                && row.detailValue(Self.scriptWorkspaceNumber(workspace.name))
                && row.flag(isActive ? UInt8(OMNI_CONFIG_BAR_FOCUSED) : 0)
        }) else { return false }
        let grouping: WorkspaceBarWindowProjector.Grouping = context.options.deduplicateAppIcons
            ? .byApp(keepsLayoutOrder: hasColumns) : .individual
        return scratch.tiled.withUnsafeBufferPointer { members in
            appendScriptBarPills(members, grouping, context, to: &output, scratch: &scratch.pills)
        } && scratch.floating.withUnsafeBufferPointer { members in
            appendScriptBarPills(members, grouping, context, to: &output, scratch: &scratch.pills)
        }
    }

    private func collectScriptBarMembers(
        in workspace: WorkspaceDescriptor, _ context: ScriptBarContext, scratch: inout ConfigScriptBarScratch
    ) -> Bool {
        let workspaceId = workspace.id
        let windows = context.windows
        scratch.tiled.removeAll(keepingCapacity: true)
        scratch.floating.removeAll(keepingCapacity: true)
        scratch.placed.removeAll(keepingCapacity: true)
        scratch.columnTokens.removeAll(keepingCapacity: true)
        var hasColumns = false
        if settings.workspaces.configScriptLayout(for: workspace.name) == .niri,
           let root = context.niri?.root(for: workspaceId)
        {
            let columns = root.projectedColumns
            hasColumns = !columns.isEmpty
            for slot in columns.indices {
                scratch.appendTokens(of: columns[slot].windows)
            }
        }
        for index in scratch.columnTokens.indices {
            let token = scratch.columnTokens[index]
            guard isScriptBarTiled(token, in: workspaceId, context) else { continue }
            scratch.tiled.append(token)
            scratch.placed.insert(token)
        }
        for token in windows.tokens(in: workspaceId, mode: .tiling)
            where !scratch.placed.contains(token) && !isScriptBarExcluded(token, context)
        {
            scratch.tiled.append(token)
        }
        moveScriptBarHiddenLast(&scratch.tiled, tail: &scratch.hiddenTail, context.hidden)
        if context.options.showFloatingWindows {
            for token in windows.tokens(in: workspaceId, mode: .floating) where isScriptBarFloating(token, context) {
                scratch.floating.append(token)
            }
            moveScriptBarHiddenLast(&scratch.floating, tail: &scratch.hiddenTail, context.hidden)
        }
        return hasColumns
    }

    private func isScriptBarTiled(
        _ token: WindowToken, in workspaceId: WorkspaceDescriptor.ID, _ context: ScriptBarContext
    ) -> Bool {
        context.windows.withEntry(token) { $0.mode == .tiling && $0.workspaceId == workspaceId } == true
            && !isScriptBarExcluded(token, context)
    }

    private func isScriptBarFloating(_ token: WindowToken, _ context: ScriptBarContext) -> Bool {
        !context.manager.isScratchpadToken(token) && context.manager.hiddenState(for: token)?
            .isScratchpad != true
            && !isScriptBarExcluded(token, context)
    }

    private func isScriptBarExcluded(_ token: WindowToken, _ context: ScriptBarContext) -> Bool {
        guard !context.options.excludedBundleIDs.isEmpty else { return false }
        let replacement = context.windows.withEntry(token) { $0.managedReplacementMetadata?.bundleId }
        return context.options.excludes(bundleId: (replacement ?? nil) ?? context.cache.cachedBundleId(for: token.pid))
    }

    private func moveScriptBarHiddenLast(
        _ members: inout [WindowToken], tail: inout [WindowToken], _ hidden: Set<pid_t>
    ) {
        guard !hidden.isEmpty else { return }
        tail.removeAll(keepingCapacity: true)
        var write = 0
        for read in members.indices {
            let token = members[read]
            if hidden.contains(token.pid) {
                tail.append(token)
            } else {
                members[write] = token
                write += 1
            }
        }
        for token in tail {
            members[write] = token
            write += 1
        }
    }

    private func appendScriptBarPills(
        _ members: UnsafeBufferPointer<WindowToken>, _ grouping: WorkspaceBarWindowProjector.Grouping,
        _ context: ScriptBarContext, to output: inout ConfigScriptSnapshotWriter, scratch: inout ScriptBarPillScratch
    ) -> Bool {
        guard !members.isEmpty else { return true }
        let source = ScriptBarPillSource(
            tokens: members, windows: context.windows, cache: context.cache,
            focused: context.focused, hidden: context.hidden
        )
        let sorted: Bool
        switch grouping {
        case .individual:
            scratch.grouping.group(count: members.count, deduplicating: false, source: source)
            sorted = false
        case let .byApp(keepsLayoutOrder):
            scratch.grouping.group(count: members.count, deduplicating: true, source: source)
            sorted = !keepsLayoutOrder
        }
        orderScriptBarPills(sorted: sorted, source, scratch: &scratch)
        for slot in scratch.order.indices {
            let pill = scratch.grouping.pills[scratch.order[slot]]
            let stored = output.row { row in
                writeScriptBarPill(pill, source, grouping: scratch.grouping, session: context.session, to: &row)
            }
            guard stored else { return false }
        }
        return true
    }

    private func orderScriptBarPills(sorted: Bool, _ source: ScriptBarPillSource, scratch: inout ScriptBarPillScratch) {
        scratch.order.removeAll(keepingCapacity: true)
        scratch.order.append(contentsOf: scratch.grouping.pills.indices)
        guard sorted, scratch.order.count > 1 else { return }
        scratch.names.removeAll(keepingCapacity: true)
        let unknown = String(localized: "Unknown")
        for pill in scratch.grouping.pills.indices {
            let named = scriptBarNamedMember(of: scratch.grouping.pills[pill], source, grouping: scratch.grouping)
            scratch.names.append(scriptBarName(of: named, source) ?? unknown)
        }
        for slot in 1 ..< scratch.order.count {
            var current = slot
            while current > 0, sortsBefore(scratch.order[current], scratch.order[current - 1], scratch: scratch) {
                scratch.order.swapAt(current, current - 1)
                current -= 1
            }
        }
    }

    private func sortsBefore(_ first: Int, _ second: Int, scratch: borrowing ScriptBarPillScratch) -> Bool {
        WorkspaceBarPill.sortsBefore(
            .init(hidden: scratch.grouping.pills[first].isAppHidden, position: scratch.grouping.pills[first].position),
            named: scratch.names[first],
            .init(
                hidden: scratch.grouping.pills[second].isAppHidden,
                position: scratch.grouping.pills[second].position
            ),
            named: scratch.names[second]
        )
    }

    private func writeScriptBarPill(
        _ pill: WorkspaceBarPill, _ source: ScriptBarPillSource, grouping: borrowing WorkspaceBarPillGrouping,
        session: ConfigScriptSession, to row: inout ConfigScriptSnapshotWriter
    ) -> Bool {
        let first = source.tokens[grouping.members[pill.start]]
        let named = scriptBarNamedMember(of: pill, source, grouping: grouping)
        guard row.flag(UInt8(OMNI_CONFIG_BAR_ROW_PILL)), row.windowID(first, session: session),
              writeScriptBarBundle(of: first, source, to: &row), writeScriptBarName(of: named, source, to: &row),
              row.flag(pill.isFocused ? UInt8(OMNI_CONFIG_BAR_FOCUSED) : 0),
              row.detailValue(UInt16(truncatingIfNeeded: pill.count))
        else { return false }
        for index in pill.start ..< pill.start + pill.count {
            let token = source.tokens[grouping.members[index]]
            guard row.windowID(token, session: session), writeScriptBarTitle(of: token, named: named, source, to: &row),
                  row.flag(token == source.focused ? UInt8(OMNI_CONFIG_BAR_FOCUSED) : 0)
            else { return false }
        }
        return true
    }

    private func scriptBarNamedMember(
        of pill: WorkspaceBarPill, _ source: ScriptBarPillSource, grouping: borrowing WorkspaceBarPillGrouping
    ) -> WindowToken {
        for index in pill.start ..< pill.start + pill.count {
            let token = source.tokens[grouping.members[index]]
            if source.cache.hasCachedInfo(for: token.pid) { return token }
        }
        return source.tokens[grouping.members[pill.start]]
    }

    private func scriptBarName(of token: WindowToken, _ source: ScriptBarPillSource) -> String? {
        let hosted = source.windows.withEntry(token) { $0.target.hostedMetadata?.title }
        if let hosted = hosted ?? nil { return hosted }
        var name: String?
        source.cache.withCachedIdentity(for: token.pid) { _, cached in name = copy cached }
        return name
    }

    private func writeScriptBarBundle(
        of token: WindowToken, _ source: ScriptBarPillSource, to row: inout ConfigScriptSnapshotWriter
    ) -> Bool {
        let replaced = source.windows.withEntry(token) { entry -> Bool? in
            guard let bundle = entry.managedReplacementMetadata?.bundleId, WorkspaceBarAppKey.bundle(bundle) != nil
            else { return nil }
            return row.string(bundle)
        }
        if let replaced = replaced ?? nil { return replaced }
        return source.cache.withCachedBundleId(for: token.pid) { row.string($0) }
    }

    private func writeScriptBarName(
        of token: WindowToken, _ source: ScriptBarPillSource, to row: inout ConfigScriptSnapshotWriter
    ) -> Bool {
        let hosted = source.windows.withEntry(token) { entry -> Bool? in
            entry.target.hostedMetadata.map { row.string($0.title) }
        }
        if let hosted = hosted ?? nil { return hosted }
        var stored = false
        source.cache.withCachedIdentity(for: token.pid) { _, name in stored = row.string(name) }
        return stored
    }

    private func writeScriptBarTitle(
        of token: WindowToken, named: WindowToken, _ source: ScriptBarPillSource,
        to row: inout ConfigScriptSnapshotWriter
    ) -> Bool {
        let hosted = source.windows.withEntry(token) { entry -> Bool? in
            entry.target.hostedMetadata.map { row.string($0.title) }
        }
        if let hosted = hosted ?? nil { return hosted }
        let cached = AXWindowService.withCachedTitle(windowId: UInt32(truncatingIfNeeded: token.windowId)) { title in
            title == nil || title!.isEmpty ? nil : row.string(title)
        }
        return cached ?? writeScriptBarName(of: named, source, to: &row)
    }
}
