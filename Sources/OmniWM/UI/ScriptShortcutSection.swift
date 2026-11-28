// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import SwiftUI

struct ScriptShortcutSection: View {
    let bindings: [ConfigScriptBinding]
    let masked: Set<KeyBinding>

    var body: some View {
        Section("Script Shortcuts") {
            ForEach(bindings.indices, id: \.self) { index in
                let binding = bindings[index]
                LabeledContent {
                    VStack(alignment: .trailing) {
                        Text(verbatim: binding.rawChord)
                        if let modeName = binding.modeName {
                            Text("In the \(modeName) key mode").font(.caption)
                        }
                        if let modeKey = binding.modeKey {
                            HStack {
                                Text("Mode Key")
                                Text(verbatim: modeKey.displayString)
                            }
                            .font(.caption)
                        }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: binding.commandText)
                        Text(verbatim: binding.sourceLocation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if binding.mode == nil, masked.contains(binding.chord) {
                            Text("Not registered")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .textSelection(.enabled)
            }
        }
    }
}
