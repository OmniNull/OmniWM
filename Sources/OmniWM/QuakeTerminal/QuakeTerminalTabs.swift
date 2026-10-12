// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Cocoa
import GhosttyKit

@MainActor
final class QuakeTerminalTabs: QuakeTerminalTabBarDelegate {
    private enum Mutation {
        case newTab
        case closeTab(ghostty_action_close_tab_mode_e)
        case split(SplitDirection, before: Bool)
    }

    private weak var window: QuakeTerminalWindow?
    private var containerView: NSView?
    private var tabBar: QuakeTerminalTabBar?
    private var makeSurfaceView: (() -> GhosttySurfaceView?)?
    private var onLastTabClosed: (() -> Void)?

    func connect(makeSurfaceView: @escaping () -> GhosttySurfaceView?, onLastTabClosed: @escaping () -> Void) {
        self.makeSurfaceView = makeSurfaceView
        self.onLastTabClosed = onLastTabClosed
    }

    private var tabs: [QuakeTerminalTab] = []
    private var activeTabIndex: Int = 0

    private var activeTab: QuakeTerminalTab? {
        guard activeTabIndex >= 0, activeTabIndex < tabs.count else { return nil }
        return tabs[activeTabIndex]
    }

    var surfaceView: GhosttySurfaceView? {
        activeTab?.focusedSurfaceView
    }

    func removeAll() {
        for tab in tabs {
            for view in tab.splitContainer.allSurfaceViews() {
                view.releaseSurface()
            }
        }
        tabs.removeAll()
        activeTabIndex = 0
        containerView = nil
        tabBar = nil
        window = nil
    }

    var isEmpty: Bool {
        tabs.isEmpty
    }

    func refreshSurfacesForCurrentScreen() {
        guard let container = activeTab?.splitContainer else { return }
        for view in container.allSurfaceViews() {
            view.refreshDisplayStateForCurrentScreen()
        }
    }

    func attach(to window: QuakeTerminalWindow, container: NSView) {
        self.window = window
        containerView = container
        let bar = QuakeTerminalTabBar()
        bar.delegate = self
        bar.isHidden = true
        bar.autoresizingMask = [.width]
        bar.frame = NSRect(
            x: 0,
            y: container.bounds.height - QuakeTerminalTabBar.barHeight,
            width: container.bounds.width,
            height: QuakeTerminalTabBar.barHeight
        )
        container.addSubview(bar)
        self.tabBar = bar
    }

    @discardableResult
    func createTab() -> QuakeTerminalTab? {
        guard let view = makeSurfaceView?() else { return nil }

        let splitContainer = QuakeSplitContainer(initialView: view)
        let tab = QuakeTerminalTab(splitContainer: splitContainer)
        tabs.append(tab)
        switchToTab(at: tabs.count - 1)
        return tab
    }

    func handleGhosttyAction(_ action: ghostty_action_s, from view: GhosttySurfaceView) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.splitContainer.contains(view: view) }) else { return false }
        let container = tabs[index].splitContainer
        switch action.tag {
        case GHOSTTY_ACTION_NEW_TAB:
            scheduleMutation(.newTab, from: view)
            return true
        case GHOSTTY_ACTION_CLOSE_TAB:
            let mode = action.action.close_tab_mode
            guard mode == GHOSTTY_ACTION_CLOSE_TAB_MODE_THIS || mode == GHOSTTY_ACTION_CLOSE_TAB_MODE_OTHER
                || mode == GHOSTTY_ACTION_CLOSE_TAB_MODE_RIGHT else { return false }
            scheduleMutation(.closeTab(mode), from: view)
            return true
        case GHOSTTY_ACTION_NEW_SPLIT:
            let mutation: Mutation
            switch action.action.new_split {
            case GHOSTTY_SPLIT_DIRECTION_RIGHT: mutation = .split(.horizontal, before: false)
            case GHOSTTY_SPLIT_DIRECTION_DOWN: mutation = .split(.vertical, before: false)
            case GHOSTTY_SPLIT_DIRECTION_LEFT: mutation = .split(.horizontal, before: true)
            case GHOSTTY_SPLIT_DIRECTION_UP: mutation = .split(.vertical, before: true)
            default: return false
            }
            scheduleMutation(mutation, from: view)
            return true
        case GHOSTTY_ACTION_GOTO_TAB:
            return goToTab(action.action.goto_tab, from: index)
        case GHOSTTY_ACTION_GOTO_SPLIT:
            return goToSplit(action.action.goto_split, from: view, in: container, tabIndex: index)
        case GHOSTTY_ACTION_EQUALIZE_SPLITS:
            container.equalize()
            return true
        default:
            return false
        }
    }

    private func scheduleMutation(_ mutation: Mutation, from view: GhosttySurfaceView) {
        DispatchQueue.main.async { [weak self, weak view] in
            guard let self, let view,
                  let index = self.tabs.firstIndex(where: { $0.splitContainer.contains(view: view) }) else { return }
            switch mutation {
            case .newTab:
                self.createTab()
            case let .split(direction, before):
                guard let newView = self.makeSurfaceView?() else { return }
                let container = self.tabs[index].splitContainer
                container.split(view: view, direction: direction, newView: newView, before: before)
                if index == self.activeTabIndex { self.window?.makeFirstResponder(newView) }
            case let .closeTab(mode):
                for candidate in self.tabs.indices.reversed() {
                    if mode == GHOSTTY_ACTION_CLOSE_TAB_MODE_THIS && candidate == index
                        || mode == GHOSTTY_ACTION_CLOSE_TAB_MODE_OTHER && candidate != index
                        || mode == GHOSTTY_ACTION_CLOSE_TAB_MODE_RIGHT && candidate > index
                    {
                        self.closeTab(at: candidate)
                    }
                }
            }
        }
    }

    private func goToTab(_ destination: ghostty_action_goto_tab_e, from index: Int) -> Bool {
        let target: Int
        switch destination {
        case GHOSTTY_GOTO_TAB_PREVIOUS: target = (index - 1 + tabs.count) % tabs.count
        case GHOSTTY_GOTO_TAB_NEXT: target = (index + 1) % tabs.count
        case GHOSTTY_GOTO_TAB_LAST: target = tabs.count - 1
        default: target = Int(destination.rawValue) - 1
        }
        guard tabs.indices.contains(target), target != activeTabIndex else { return false }
        switchToTab(at: target)
        return true
    }

    private func goToSplit(
        _ destination: ghostty_action_goto_split_e,
        from view: GhosttySurfaceView,
        in container: QuakeSplitContainer,
        tabIndex: Int
    ) -> Bool {
        let target: GhosttySurfaceView?
        switch destination {
        case GHOSTTY_GOTO_SPLIT_PREVIOUS,
             GHOSTTY_GOTO_SPLIT_NEXT:
            let views = container.allSurfaceViews()
            guard let index = views.firstIndex(where: { $0 === view }), views.count > 1 else { return false }
            let offset = destination == GHOSTTY_GOTO_SPLIT_NEXT ? 1 : -1
            target = views[(index + offset + views.count) % views.count]
        default:
            let direction: NavigationDirection
            switch destination {
            case GHOSTTY_GOTO_SPLIT_LEFT: direction = .left
            case GHOSTTY_GOTO_SPLIT_RIGHT: direction = .right
            case GHOSTTY_GOTO_SPLIT_UP: direction = .up
            case GHOSTTY_GOTO_SPLIT_DOWN: direction = .down
            default: return false
            }
            target = container.root.findNeighbor(of: view, direction: direction, in: container.bounds)
        }
        guard let target else { return false }
        if tabIndex != activeTabIndex { switchToTab(at: tabIndex) }
        container.focus(view: target)
        return true
    }

    func closeTab(at index: Int) {
        guard index >= 0, index < tabs.count else { return }

        let tab = tabs[index]
        for view in tab.splitContainer.allSurfaceViews() {
            view.releaseSurface()
        }
        tab.splitContainer.removeFromSuperview()
        tabs.remove(at: index)

        if tabs.isEmpty {
            activeTabIndex = 0
            updateTabBarVisibility()
            onLastTabClosed?()
            return
        }

        if activeTabIndex >= tabs.count {
            activeTabIndex = tabs.count - 1
        } else if activeTabIndex > index {
            activeTabIndex -= 1
        } else if activeTabIndex == index {
            activeTabIndex = min(activeTabIndex, tabs.count - 1)
        }

        switchToTab(at: activeTabIndex)
    }

    func switchToTab(at index: Int) {
        guard index >= 0, index < tabs.count else { return }

        if activeTabIndex < tabs.count {
            tabs[activeTabIndex].splitContainer.removeFromSuperview()
        }

        activeTabIndex = index
        let tab = tabs[index]

        guard let containerView else { return }
        let showBar = tabs.count > 1
        let barHeight = showBar ? QuakeTerminalTabBar.barHeight : 0
        let surfaceFrame = NSRect(
            x: 0, y: 0,
            width: containerView.bounds.width,
            height: containerView.bounds.height - barHeight
        )
        tab.splitContainer.frame = surfaceFrame
        tab.splitContainer.autoresizingMask = [.width, .height]
        containerView.addSubview(tab.splitContainer)

        if let focused = tab.focusedSurfaceView {
            window?.makeFirstResponder(focused)
        }

        updateTabBarVisibility()
        tab.splitContainer.relayout()
    }

    func updateTabBarVisibility() {
        guard let tabBar, let containerView else { return }
        let showBar = tabs.count > 1
        tabBar.isHidden = !showBar

        if showBar {
            tabBar.frame = NSRect(
                x: 0,
                y: containerView.bounds.height - QuakeTerminalTabBar.barHeight,
                width: containerView.bounds.width,
                height: QuakeTerminalTabBar.barHeight
            )
            tabBar.update(
                titles: tabs.map { $0.title },
                selectedIndex: activeTabIndex
            )
        }

        if let activeContainer = activeTab?.splitContainer {
            let barHeight = showBar ? QuakeTerminalTabBar.barHeight : 0
            activeContainer.frame = NSRect(
                x: 0, y: 0,
                width: containerView.bounds.width,
                height: containerView.bounds.height - barHeight
            )
            activeContainer.relayout()
        }
    }

    func surfaceClosed(_ closedView: GhosttySurfaceView) {
        guard let tabIndex = tabs.firstIndex(where: { $0.splitContainer.contains(view: closedView) }) else {
            closedView.releaseSurface()
            return
        }

        let tab = tabs[tabIndex]
        if tab.splitContainer.root.leafCount() <= 1 {
            closeTab(at: tabIndex)
            return
        }

        if tab.splitContainer.remove(view: closedView) {
            closedView.releaseSurface()
            if tabIndex == activeTabIndex, let newFocus = tab.splitContainer.focusedView {
                window?.makeFirstResponder(newFocus)
            }
        }
    }

    func tabBarDidSelectTab(at index: Int) {
        switchToTab(at: index)
    }

    func tabBarDidRequestNewTab() {
        createTab()
    }

    func tabBarDidRequestCloseTab(at index: Int) {
        closeTab(at: index)
    }
}
