// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import OmniWMIPC

struct ShellDragState: Equatable {
    var sources: Set<WindowToken> = []
    var highlights: [WorkspaceBarDropHighlight] = []
}

extension ShellBarDrag {
    init?(_ state: ShellDragState, snapshot: WorkspaceBarSnapshot, sessionToken: String) {
        guard !state.sources.isEmpty || !state.highlights.isEmpty else { return nil }
        let names = Dictionary(snapshot.items.map { ($0.id, $0.rawName) }) { first, _ in first }
        let id = { (token: WindowToken) in
            IPCWindowOpaqueID.encode(pid: token.pid, windowId: token.windowId, sessionToken: sessionToken)
        }
        self.init(sources: state.sources.map(id).sorted())
        for highlight in state.highlights {
            switch highlight {
            case let .workspace(workspace):
                workspaces += names[workspace].map { [$0] } ?? []
            case let .gap(workspace, before):
                gaps += names[workspace].map { [Gap(workspace: $0, before: before + 1)] } ?? []
            case let .icon(_, token):
                icons.append(id(token))
            }
        }
    }
}

extension ShellBarStyle {
    @MainActor
    init(_ resolved: ResolvedBarSettings, settings: WorkspaceBarSettings, snapshot: WorkspaceBarSnapshot) {
        let hex = { (color: SettingsColor?) -> String? in
            color.map { color in
                String(
                    format: "#%02X%02X%02X%02X",
                    Int((color.red * 255).rounded()),
                    Int((color.green * 255).rounded()),
                    Int((color.blue * 255).rounded()),
                    Int((color.alpha * 255).rounded())
                )
            }
        }
        self.init(
            height: Double(snapshot.barHeight),
            labels: resolved.showLabels,
            backgrounds: resolved.showItemBackgrounds,
            accents: resolved.showAccentHighlights,
            inactive: resolved.inactiveIconOpacity ?? -1,
            position: resolved.position.rawValue,
            vertical: resolved.position.isVertical,
            notch: resolved.notchMode.rawValue,
            notchWidth: resolved.notchActiveZoneWidth,
            level: resolved.windowLevel.rawValue,
            offsetX: resolved.xOffset,
            offsetY: resolved.yOffset,
            autoHide: resolved.autoHide,
            reveal: settings.resolvedRevealModifier.rawValue,
            opacity: resolved.backgroundOpacity,
            transparent: resolved.transparentBackground,
            solidBlack: resolved.solidBlackBackground,
            accentColor: hex(resolved.accentColor),
            textColor: hex(resolved.textColor),
            statsButton: resolved.systemStatsButton,
            secureInput: snapshot.secureInputActive,
            keyboardMode: snapshot.keyboardMode.rawValue,
            previews: settings.resolvedHoverPreviewsEnabled,
            hideInFullscreen: settings.resolvedHideInNativeFullscreen,
            hidesMenuBar: WorkspaceBarManager.coversAppMenus(resolved)
        )
    }
}

extension ShellBarData {
    @MainActor
    init(
        monitor: Monitor,
        snapshot: WorkspaceBarSnapshot,
        style: ShellBarStyle,
        sessionToken: String,
        badges: WorkspaceBarBadgeService,
        icons: inout [String: NSImage]
    ) {
        let projection = snapshot.projection
        self.monitor = monitor.name
        self.badges = badges.mode.rawValue
        self.style = style
        var resolved: [String: NSImage] = [:]
        let items = { (windows: [WorkspaceBarWindowItem], floating: Bool) in
            windows.map { window in
                var item = Self.item(window, sessionToken: sessionToken, badges: badges)
                item.floating = floating
                resolved[item.id] = window.icon
                return item
            }
        }
        workspaces = projection.items.map { item in
            ShellBarWorkspace(
                id: item.rawName,
                name: item.name,
                focused: item.isFocused,
                windows: items(item.tiledWindows, false) + items(item.floatingWindows, true)
            )
        }
        scratchpads = projection.scratchpads.map { scratchpad in
            ShellBarScratchpad(
                id: scratchpad.index,
                name: scratchpad.name,
                focused: scratchpad.isFocused,
                revealed: scratchpad.isRevealed,
                visible: scratchpad.isVisible,
                windows: items(scratchpad.windows, false)
            )
        }
        icons.merge(resolved) { current, _ in current }
    }

    @MainActor
    private static func item(
        _ window: WorkspaceBarWindowItem,
        sessionToken: String,
        badges: WorkspaceBarBadgeService
    ) -> ShellBarItem {
        let windows = window.allWindows.map { info in
            ShellBarWindow(
                id: id(info.id, sessionToken),
                title: info.title,
                focused: info.isFocused,
                hidden: info.isAppHidden
            )
        }
        return ShellBarItem(
            id: window.allWindows.first?.id == window.id ? windows[0].id : id(window.id, sessionToken),
            bundle: window.bundleId ?? "",
            name: window.appName,
            focused: window.isFocused,
            count: window.windowCount,
            hidden: window.hiddenWindowCount,
            badge: badges.label(for: window.bundleId) ?? "",
            windows: windows
        )
    }

    private static func id(_ token: WindowToken, _ sessionToken: String) -> String {
        IPCWindowOpaqueID.encode(pid: token.pid, windowId: token.windowId, sessionToken: sessionToken)
    }
}
