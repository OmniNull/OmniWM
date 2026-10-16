// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import SwiftUI

struct AppRulesView: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    let editorState: AppRulesEditorState

    @State private var selectedRuleId: AppRule.ID?
    @State private var addDraft: AppRuleDraft?
    @State private var pendingDeleteRule: AppRule?
    @State private var searchText = ""
    @State private var pendingSelection: AppRule.ID?
    @State private var pendingDraft: AppRuleDraft?
    @State private var isConfirmingDiscard = false

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 760
            let layout = wide ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                AppRulesSidebar(
                    rules: settings.appRules,
                    searchText: $searchText,
                    selection: selectionBinding,
                    onAdd: { presentNewRule() },
                    onDelete: { pendingDeleteRule = $0 },
                    onMove: moveHandler
                )
                .frame(width: wide ? 230 : nil)
                .frame(maxHeight: wide ? .infinity : selectedRuleId == nil ? 220 : 0)
                .clipped()
                VStack(alignment: .leading, spacing: 0) {
                    if !wide, selectedRuleId != nil {
                        Button("All Rules", systemImage: "chevron.left") { selectionBinding.wrappedValue = nil }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                    }
                    detailColumn
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            }
        }
        .sheet(item: $addDraft, content: addSheet)
        .onAppear(perform: presentRequestedDraft)
        .onChange(of: editorState.requestedDraft?.id) { _, _ in presentRequestedDraft() }
        .confirmationDialog(
            "Delete app rule?",
            isPresented: isConfirmingDelete,
            presenting: pendingDeleteRule
        ) { rule in
            Button("Delete Rule", role: .destructive) {
                deleteRule(rule)
            }
            Button("Cancel", role: .cancel) {}
        } message: { rule in
            Text("Delete the rule for \(rule.displayLabel)?")
        }
        .confirmationDialog(
            "Discard unsaved changes?",
            isPresented: $isConfirmingDiscard
        ) {
            Button("Discard Changes", role: .destructive) {
                editorState.isDirty = false
                if let pendingDraft {
                    selectedRuleId = nil
                    addDraft = pendingDraft
                    self.pendingDraft = nil
                } else {
                    selectedRuleId = pendingSelection
                }
            }
            Button("Cancel", role: .cancel) { pendingDraft = nil }
        } message: {
            Text("You have unsaved changes to this app rule.")
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private var selectionBinding: Binding<AppRule.ID?> {
        Binding(
            get: { selectedRuleId },
            set: { newValue in
                if editorState.isDirty {
                    pendingSelection = newValue
                    isConfirmingDiscard = true
                } else {
                    selectedRuleId = newValue
                }
            }
        )
    }

    @ViewBuilder private var detailColumn: some View {
        if let ruleId = selectedRuleId,
           let ruleIndex = settings.appRules.firstIndex(where: { $0.id == ruleId })
        {
            AppRuleDetailView(
                rule: $settings.appRules[ruleIndex],
                workspaceNames: workspaceNames,
                controller: controller,
                editorState: editorState,
                onCreateRuleFromSnapshot: presentNewRule(from:),
                onDelete: { pendingDeleteRule = settings.appRules[ruleIndex] }
            )
            .id(ruleId)
        } else {
            AppRulesEmptyState(
                controller: controller,
                onAdd: { presentNewRule() },
                onCreateRuleFromSnapshot: presentNewRule(from:)
            )
        }
    }

    private func addSheet(_ draft: AppRuleDraft) -> AppRuleAddSheet {
        AppRuleAddSheet(
            initialDraft: draft,
            workspaceNames: workspaceNames,
            controller: controller,
            onSave: { newRule in
                settings.appRules.append(newRule)
                controller.updateAppRules()
                selectedRuleId = newRule.id
                addDraft = nil
            },
            onCancel: { addDraft = nil }
        )
    }

    private var workspaceNames: [String] {
        settings.workspaces.configurations.map(\.name)
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var moveHandler: ((IndexSet, Int) -> Void)? {
        guard !isSearching else { return nil }
        return { source, destination in
            settings.appRules.move(fromOffsets: source, toOffset: destination)
            controller.updateAppRules()
        }
    }

    private var isConfirmingDelete: Binding<Bool> {
        Binding(
            get: { pendingDeleteRule != nil },
            set: { isPresented in
                if !isPresented {
                    pendingDeleteRule = nil
                }
            }
        )
    }

    private func deleteRule(_ rule: AppRule) {
        settings.appRules.removeAll { $0.id == rule.id }
        controller.updateAppRules()
        if selectedRuleId == rule.id {
            selectedRuleId = nil
        }
    }

    private func presentRequestedDraft() {
        guard let draft = editorState.requestedDraft else { return }
        editorState.requestedDraft = nil
        selectedRuleId = nil
        presentNewRule(draft)
    }

    private func presentNewRule(_ draft: AppRuleDraft = AppRuleDraft()) {
        if editorState.isDirty {
            pendingDraft = draft
            isConfirmingDiscard = true
        } else {
            addDraft = draft
        }
    }

    private func presentNewRule(from snapshot: WindowDecisionDebugSnapshot) {
        guard let draft = AppRuleDraft.guided(from: snapshot) else { return }
        presentNewRule(draft)
    }
}

struct AppRulesSidebar: View {
    let rules: [AppRule]
    @Binding var searchText: String
    @Binding var selection: AppRule.ID?
    let onAdd: () -> Void
    let onDelete: (AppRule) -> Void
    let onMove: ((IndexSet, Int) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Search rules", text: $searchText)
                .textFieldStyle(.roundedBorder)
            Button("Add Rule", systemImage: "plus", action: onAdd)
            List(selection: $selection) {
                ForEach(filteredRules) { rule in
                    AppRuleSidebarRow(rule: rule)
                        .tag(rule.id)
                        .contextMenu {
                            Button(role: .destructive) {
                                onDelete(rule)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
                .onMove(perform: onMove)

                if rules.count > 1, onMove != nil {
                    Text("More specific rules win; ties break by order — drag to reorder.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.inset)
            .overlay {
                if !rules.isEmpty, filteredRules.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else if rules.isEmpty {
                    ContentUnavailableView(
                        "No App Rules",
                        systemImage: "app.badge.checkmark",
                        description: Text("Add a rule to choose how an app’s windows are managed.")
                    )
                }
            }
        }
        .padding(12)
    }

    private var filteredRules: [AppRule] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return rules }
        return rules.filter { rule in
            if rule.displayLabel.lowercased().contains(query) { return true }
            if rule.bundleId.lowercased().contains(query) { return true }
            return [rule.appNameSubstring, rule.titleSubstring, rule.titleRegex, rule.axRole, rule.axSubrole]
                .compactMap { $0?.lowercased() }
                .contains { $0.contains(query) }
        }
    }
}

struct AppRuleSidebarRow: View {
    let rule: AppRule

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.displayLabel)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)

                HStack(spacing: 4) {
                    badges
                }
            }

            Spacer()

            Text(rule.specificity.formatted())
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .help("Match specificity \(rule.specificity) — higher specificity wins; ties break by list order")
                .accessibilityLabel("Specificity \(rule.specificity)")
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var badges: some View {
        switch rule.effectiveLayoutAction {
        case .float:
            RuleBadge(text: String(localized: "Float"), color: .blue, accessibilityLabel: String(localized: "Floating"))
        case .tile:
            RuleBadge(text: String(localized: "Tile"), color: .teal, accessibilityLabel: String(localized: "Tiled"))
        case .auto:
            EmptyView()
        }
        if let workspace = rule.assignToWorkspace {
            RuleBadge(
                text: String(localized: "WS"),
                color: .green,
                accessibilityLabel: String(localized: "Assigned to workspace \(workspace)")
            )
        }
        if let width = rule.validInitialContainerPrimarySpan {
            let percent = AppRulePrimarySpanPercent.displayText(for: width)
            RuleBadge(
                text: String(localized: "Primary \(percent)%"),
                color: .indigo,
                accessibilityLabel: String(localized: "Initial Niri container primary span \(percent) percent")
            )
        } else if rule.initialContainerPrimarySpan != nil {
            RuleBadge(
                text: String(localized: "Primary invalid"),
                color: .red,
                accessibilityLabel: String(localized: "Invalid initial Niri container primary span")
            )
        }
        if rule.minWidth != nil || rule.minHeight != nil {
            RuleBadge(
                text: String(localized: "Size"),
                color: .orange,
                accessibilityLabel: String(localized: "Minimum size set")
            )
        }
        if rule.hasAdvancedMatchers {
            RuleBadge(
                text: String(localized: "Advanced"),
                color: .purple,
                accessibilityLabel: String(localized: "Advanced matchers")
            )
        }
    }
}

struct AppRulesEmptyState: View {
    let controller: WMController
    let onAdd: () -> Void
    let onCreateRuleFromSnapshot: (WindowDecisionDebugSnapshot) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ContentUnavailableView {
                    Label("No App Rule Selected", systemImage: "app.badge.checkmark")
                } description: {
                    Text("Select a rule from the sidebar to edit it, or add a new rule to get started.")
                } actions: {
                    Button("Add Rule", action: onAdd)
                        .buttonStyle(.borderedProminent)
                }

                FocusedWindowInspectorView(
                    controller: controller,
                    onCreateRuleFromSnapshot: onCreateRuleFromSnapshot
                )
                .frame(maxWidth: 560)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct RuleBadge: View {
    let text: String
    let color: Color
    var accessibilityLabel: String?

    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.2))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .accessibilityLabel(accessibilityLabel ?? text)
    }
}
