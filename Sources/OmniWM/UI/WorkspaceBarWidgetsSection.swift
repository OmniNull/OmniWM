// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import SwiftUI

struct WorkspaceBarWidgetsSection: View {
    let configuration: ShellConfigurationCoordinator
    let vertical: Bool?
    @Environment(SettingsNavigationModel.self) private var navigation
    @State private var problem: String?
    @State private var selection: String?
    @State private var confirmingReset = false
    @State private var adding = false
    @State private var destination: ShellLane = .trailing
    @State private var query = ""

    private var layout: ShellBarLayout? {
        configuration.barLayout
    }

    var body: some View {
        Section("Bar Widgets") {
            if let layout {
                SettingsCaption(localized: "Arrange your widgets. The layout is shared by all displays in this style.")
                widgetList(layout)
                HStack {
                    Button("Add Widget…", systemImage: "plus") { adding = true }
                        .disabled(layout.addable.isEmpty)
                    if let selection, let lane = layout.lane(of: selection) {
                        Menu("Move") {
                            Button("Move Earlier") { edit { $0.shift(selection, by: -1) } }
                                .disabled(layout.names(in: lane).first == selection)
                            Button("Move Later") { edit { $0.shift(selection, by: 1) } }
                                .disabled(layout.names(in: lane).last == selection)
                            Divider()
                            ForEach(ShellLane.allCases.filter { $0 != lane }, id: \.self) { target in
                                Button("Move to \(ShellBarLayout.side(target, vertical: vertical))") {
                                    edit { $0.move(selection, to: target) }
                                }
                            }
                        }
                        Button("Options…") {
                            navigation.request(SettingsRoute(section: .widgets, itemID: selection))
                        }
                        Button("Remove", role: .destructive) {
                            edit { $0.remove(selection) }
                            self.selection = nil
                        }
                    }
                }
                Button("Use Style Layout…") { confirmingReset = true }
                    .disabled(!layout.customized)
            } else if let problem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                Button("Try Again") {
                    Task {
                        do { try await configuration.refresh()
                            reload()
                        } catch { self.problem = error.localizedDescription }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .id("Bar Widgets")
        .onAppear(perform: reload)
        .onChange(of: configuration.barLayout) { _, _ in reload() }
        .onChange(of: configuration.metadataError) { _, _ in reload() }
        .confirmationDialog("Use this style’s widget layout?", isPresented: $confirmingReset) {
            Button("Use Style Layout", role: .destructive) {
                Task {
                    do {
                        try await configuration.resetBarLayout()
                        selection = nil
                        reload()
                    } catch { problem = error.localizedDescription }
                }
            }
        }
        .sheet(isPresented: $adding) { addSheet }
    }

    private func widgetList(_ layout: ShellBarLayout) -> some View {
        List(selection: $selection) {
            ForEach(ShellLane.allCases, id: \.self) { lane in
                widgetLane(lane, layout: layout)
            }
        }
        .listStyle(.bordered)
        .frame(height: min(
            340,
            CGFloat(layout.leading.count + layout.center.count + layout.trailing.count + 3) * 30 + 45
        ))
    }

    private func widgetLane(_ lane: ShellLane, layout: ShellBarLayout) -> some View {
        Section(ShellBarLayout.side(lane, vertical: vertical)) {
            if layout.names(in: lane).isEmpty {
                Text("No widgets").foregroundStyle(.secondary).selectionDisabled()
            }
            ForEach(layout.names(in: lane), id: \.self) { name in
                Label(
                    ShellBarLayout.title(of: name),
                    systemImage: layout.source(of: name) == nil
                        ? "exclamationmark.triangle" : "puzzlepiece.extension"
                )
                .tag(name)
            }
            .onMove { offsets, index in edit { $0.move(in: lane, from: offsets, to: index) } }
        }
    }

    private var addSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Bar Widget").font(.title2.bold())
            TextField("Search widgets", text: $query).textFieldStyle(.roundedBorder)
            Picker("Place in", selection: $destination) {
                ForEach(ShellLane.allCases, id: \.self) { lane in
                    Text(ShellBarLayout.side(lane, vertical: vertical)).tag(lane)
                }
            }
            List {
                ForEach((layout?.addable ?? []).filter {
                    query.isEmpty || ShellBarLayout.title(of: $0.name).localizedStandardContains(query)
                }) { widget in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(ShellBarLayout.title(of: widget.name)).fontWeight(.medium)
                            Text(ShellWidgetSettingsModel.description(widget.name)).font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Add") {
                            edit { $0.add(widget.name, to: destination) }
                            selection = widget.name
                            adding = false
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .frame(minHeight: 240)
            HStack { Spacer()
                Button("Done") { adding = false }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 460, idealWidth: 560, minHeight: 400)
    }

    private func edit(_ change: @escaping @MainActor (inout ShellBarLayout) -> Void) {
        Task {
            do { try await configuration.editBar(change)
                reload()
            } catch { problem = error.localizedDescription }
        }
    }

    private func reload() {
        problem = layout == nil ? configuration.metadataError : nil
        if let selection, layout?.lane(of: selection) == nil { self.selection = nil }
    }
}
