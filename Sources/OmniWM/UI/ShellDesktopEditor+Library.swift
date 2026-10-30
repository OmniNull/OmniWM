// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension ShellDesktopEditor {
    enum LibraryTarget: Hashable {
        case bar
        case island
        case drawer(String)
    }

    struct LibraryEntry: Identifiable, Equatable {
        let name: String
        let title: String
        let icon: String
        let summary: String
        var available = true
        var problem: String?

        var id: String {
            name
        }
    }

    var metadataProblem: String? {
        scope == .active ? configuration.metadataError : nil
    }

    func libraryEntries(_ target: LibraryTarget) -> [LibraryEntry] {
        switch target {
        case .bar:
            return (layout?.addable ?? []).map { libraryEntry($0.name) }
        case .island:
            return islandEntries.map {
                LibraryEntry(
                    name: $0.widget, title: $0.descriptor.map { strings.title($0.title) }
                        ?? ShellBarLayout.title(of: $0.widget),
                    icon: $0.descriptor?.icon ?? "exclamationmark.triangle",
                    summary: ShellWidgetSettingsModel.description($0.widget),
                    available: $0.descriptor != nil, problem: $0.error
                )
            }
        case let .drawer(id):
            return drawerCandidates(id).map(libraryEntry)
        }
    }

    @discardableResult
    func libraryAdd(_ name: String, to target: LibraryTarget, lane: ShellLane = .trailing) async -> Bool {
        switch target {
        case .bar: await add(name, to: lane)
        case .island: await addComponent(name)
        case let .drawer(id): await addDrawerWidget(name, to: id)
        }
    }

    @discardableResult
    func showOptions(_ widget: String) async -> Bool {
        let next = Destination(surface: .bar, widget: widget, component: selectedComponent, drawer: selectedDrawer)
        guard next != destination else { return true }
        return await request(.destination(next))
    }

    private func libraryEntry(_ name: String) -> LibraryEntry {
        LibraryEntry(
            name: name, title: ShellBarLayout.title(of: name),
            icon: snapshot?.descriptors[name]?.icon ?? "puzzlepiece.extension",
            summary: ShellWidgetSettingsModel.description(name)
        )
    }
}
