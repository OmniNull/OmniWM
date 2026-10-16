// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import SwiftUI

struct IssueTextEditor: View {
    let label: String
    @Binding var text: String
    var minHeight: CGFloat

    init(_ label: String, text: Binding<String>, minHeight: CGFloat = 90) {
        self.label = label
        _text = text
        self.minHeight = minHeight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.callout)
            TextEditor(text: $text)
                .frame(minHeight: minHeight)
                .font(.body)
                .accessibilityLabel(label)
        }
    }
}
