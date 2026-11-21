// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import SwiftUI

struct ShellDesktopLanes: View {
    let editor: ShellDesktopEditor
    @State private var adding = false
    @State private var expanded = true
    @State private var priorityExpanded = true
    @State private var confirmingReset = false

    var body: some View {
        Section {
            DisclosureGroup("Widget Lanes", isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(ShellLane.allCases, id: \.self) { lane in
                        ShellDesktopChipWell(
                            label: ShellBarLayout.side(
                                lane,
                                vertical: ShellBarLayout.vertical(editor.barSettings, on: editor.monitors)
                            ),
                            names: editor.layout?.names(in: lane) ?? [],
                            space: lane.rawValue,
                            drop: { editor.drop($0, into: lane, at: $1) },
                            chip: { name, names in
                                ShellDesktopLaneChip(editor: editor, lane: lane, name: name, names: names)
                            }
                        )
                    }
                }
            }
            DisclosureGroup("Priority", isExpanded: $priorityExpanded) {
                VStack(alignment: .leading, spacing: 6) {
                    ShellDesktopChipWell(
                        label: nil,
                        names: editor.priorityOrder,
                        space: "priority",
                        drop: { editor.dropPriority($0, at: $1) },
                        chip: { name, names in
                            ShellDesktopPriorityChip(editor: editor, name: name, names: names)
                        }
                    )
                    Text("On full-width bars, widgets later in this list give way first when the bar is too full.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Add Widget…") { adding = true }
                    .disabled(editor.layout?.addable.isEmpty != false)
                Button("Use Style Layout…") { confirmingReset = true }
                    .disabled(editor.layout?.customized != true)
                Spacer(minLength: 0)
            }
        } header: {
            Text("Bar Widgets")
        } footer: {
            Text("Shared by all displays in this style.")
        }
        .shellWidgetLibrary(editor: editor, target: .bar, isPresented: $adding)
        .confirmationDialog("Use this style’s widget layout?", isPresented: $confirmingReset) {
            Button("Use Style Layout", role: .destructive) { editor.resetLayout() }
        } message: { Text("Your widget options are kept.") }
    }
}

private struct ShellDesktopChipWell<Chip: View>: View {
    static var labelWidth: CGFloat {
        58
    }

    static var padding: CGFloat {
        8
    }

    let label: String?
    let names: [String]
    let space: String
    let drop: (String, Int) -> Bool
    @ViewBuilder let chip: (String, [String]) -> Chip
    @State private var insertion: Int?
    @State private var frames: [String: CGRect] = [:]

    var body: some View {
        HStack(alignment: .top, spacing: Self.padding) {
            if let label {
                Text(label)
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(width: Self.labelWidth, height: 30, alignment: .leading)
            }
            if names.isEmpty {
                Text("Drop widget here").font(.caption).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            } else {
                let space = space
                ShellDesktopLaneLayout {
                    ForEach(names, id: \.self) { name in
                        chip(name, names)
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(space)) } action: {
                                frames[name] = $0
                            }
                    }
                }
            }
        }
        .padding(Self.padding).frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
        .overlay(alignment: .topLeading) {
            if let insertion, let marker = marker(at: insertion) {
                Rectangle().fill(Color.accentColor).frame(width: 3, height: 30)
                    .offset(x: marker.x, y: marker.y)
                    .allowsHitTesting(false)
            }
        }
        .coordinateSpace(name: space)
        .dropDestination(for: String.self) { items, session in
            guard session.localSession != nil, let item = items.first else { return }
            _ = drop(item, insertionIndex(at: session.location))
            insertion = nil
        }
        .dropConfiguration { .init(operation: $0.localSession == nil ? .forbidden : .move) }
        .onDropSessionUpdated { session in
            switch session.phase {
            case .entering,
                 .active:
                if session.localSession != nil { insertion = insertionIndex(at: session.location) }
            default: insertion = nil
            }
        }
    }

    private func insertionIndex(at point: CGPoint) -> Int {
        let ordered = names.compactMap { frames[$0] }
        guard ordered.count == names.count else { return names.count }
        return ShellDesktopLaneLayout.insertion(at: point, frames: ordered)
    }

    private func marker(at index: Int) -> CGPoint? {
        if names.isEmpty {
            return CGPoint(x: (label == nil ? 0 : Self.labelWidth + Self.padding) + Self.padding - 3, y: Self.padding)
        }
        let ordered = names.compactMap { frames[$0] }
        guard ordered.count == names.count else { return nil }
        if index < ordered.count { return CGPoint(x: ordered[index].minX - 3, y: ordered[index].minY) }
        return ordered.last.map { CGPoint(x: $0.maxX + 2, y: $0.minY) }
    }
}

private struct ShellDesktopChipLabel: View {
    let editor: ShellDesktopEditor
    let name: String

    var body: some View {
        Button { Task { await editor.selectWidget(name) } } label: {
            HStack(spacing: 4) {
                if editor.snapshot?.config.widget(name) == nil {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                Text(ShellBarLayout.title(of: name)).lineLimit(1).truncationMode(.tail)
            }
            .font(.caption).padding(.horizontal, 8).frame(height: 30)
            .background(
                editor.selectedWidget == name ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06),
                in: .rect(cornerRadius: 6)
            )
        }
        .buttonStyle(.plain)
        .help(ShellBarLayout.title(of: name))
    }
}

private struct ShellDesktopLaneChip: View {
    let editor: ShellDesktopEditor
    let lane: ShellLane
    let name: String
    let names: [String]

    var body: some View {
        ShellDesktopChipLabel(editor: editor, name: name)
            .draggable(editor.dragPayload(for: name))
            .dragConfiguration(.init(
                operationsWithinApp: .init(allowCopy: false, allowMove: true),
                operationsOutsideApp: .init(allowCopy: false)
            ))
            .contextMenu {
                Button("Move Earlier") { editor.shift(name, by: -1) }
                    .disabled(names.first == name)
                Button("Move Later") { editor.shift(name, by: 1) }.disabled(names.last == name)
                Menu("Move to") {
                    ForEach(ShellLane.allCases.filter { $0 != lane }, id: \.self) { target in
                        Button(ShellBarLayout.side(target, vertical: ShellBarLayout.vertical(
                            editor.barSettings,
                            on: editor.monitors
                        ))) {
                            editor.move(name, to: target)
                        }
                    }
                }
                Button("Remove", role: .destructive) { editor.remove(name) }
            }
    }
}

private struct ShellDesktopPriorityChip: View {
    let editor: ShellDesktopEditor
    let name: String
    let names: [String]

    var body: some View {
        ShellDesktopChipLabel(editor: editor, name: name)
            .draggable(editor.priorityPayload(for: name))
            .dragConfiguration(.init(
                operationsWithinApp: .init(allowCopy: false, allowMove: true),
                operationsOutsideApp: .init(allowCopy: false)
            ))
            .contextMenu {
                Button("Move Earlier") { editor.shiftPriority(name, by: -1) }
                    .disabled(names.first == name)
                Button("Move Later") { editor.shiftPriority(name, by: 1) }.disabled(names.last == name)
            }
    }
}
