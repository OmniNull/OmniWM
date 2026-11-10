// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

struct Sponsor: Identifiable {
    let id = UUID()
    let name: String
    let githubUsername: String?
    let imageName: String?
    let imageExtension: String?
    let creditMessage: String?

    init(
        name: String,
        githubUsername: String?,
        imageName: String?,
        imageExtension: String?,
        creditMessage: String? = nil
    ) {
        self.name = name
        self.githubUsername = githubUsername
        self.imageName = imageName
        self.imageExtension = imageExtension
        self.creditMessage = creditMessage
    }
}

private let sponsors: [Sponsor] = [
    Sponsor(name: "Christopher2K", githubUsername: "Christopher2K", imageName: "christopher2k", imageExtension: "jpg"),
    Sponsor(name: "Aelte", githubUsername: "aelte", imageName: "aelte", imageExtension: "png"),
    Sponsor(name: "captainpryce", githubUsername: "captainpryce", imageName: "captainpryce", imageExtension: "jpg"),
    Sponsor(name: "sgrimee", githubUsername: "sgrimee", imageName: "sgrimee", imageExtension: "jpg"),
    Sponsor(name: "aidansunbury", githubUsername: "aidansunbury", imageName: "aidansunbury", imageExtension: "png"),
    Sponsor(name: "dwstevens", githubUsername: "dwstevens", imageName: "dwstevens", imageExtension: "png"),
    Sponsor(name: "swilson2020", githubUsername: "swilson2020", imageName: "swilson2020", imageExtension: "jpg"),
    Sponsor(name: "Jeff Windsor", githubUsername: "jeffwindsor", imageName: "jeffwindsor", imageExtension: "png"),
    Sponsor(name: "Jason Martin", githubUsername: "jsonMartin", imageName: "jsonmartin", imageExtension: "png"),
    Sponsor(name: "dagi3d", githubUsername: "dagi3d", imageName: "dagi3d", imageExtension: "jpg"),
    Sponsor(name: "Aleksei Gurianov", githubUsername: "Guria", imageName: "guria", imageExtension: "png"),
    Sponsor(name: "Stefan Antoni", githubUsername: nil, imageName: nil, imageExtension: nil),
    Sponsor(name: "Naoki Ikeguchi", githubUsername: "siketyan", imageName: "siketyan", imageExtension: "png"),
    Sponsor(name: "Justin Miller", githubUsername: "incanus", imageName: "incanus", imageExtension: "png"),
    Sponsor(name: "benhaotang", githubUsername: "benhaotang", imageName: "benhaotang", imageExtension: "png"),
    Sponsor(name: "Chris M", githubUsername: "tebriel", imageName: "tebriel", imageExtension: "jpg"),
    Sponsor(name: "marckeelingiv", githubUsername: "marckeelingiv", imageName: "marckeelingiv", imageExtension: "png"),
    Sponsor(name: "Nader Akoury", githubUsername: "dojoteef", imageName: "dojoteef", imageExtension: "jpg"),
    Sponsor(name: "Earl Gresh", githubUsername: "earl-gresh", imageName: "earl-gresh", imageExtension: "jpg"),
    Sponsor(name: "Carson Full", githubUsername: "CarsonF", imageName: "carsonf", imageExtension: "jpg"),
    Sponsor(name: "ryoppippi", githubUsername: "ryoppippi", imageName: "ryoppippi", imageExtension: "jpg"),
    Sponsor(name: "Álvaro Barchín", githubUsername: "abarchin", imageName: "abarchin", imageExtension: "jpg"),
    Sponsor(
        name: "Marc Hendrichsen",
        githubUsername: "MarcHendrichsenO365",
        imageName: "marchendrichseno365",
        imageExtension: "png"
    ),
    Sponsor(name: "b-allan-w", githubUsername: "b-allan-w", imageName: "b-allan-w", imageExtension: "png"),
    Sponsor(name: "cafe3310", githubUsername: "cafe3310", imageName: "cafe3310", imageExtension: "png"),
    Sponsor(name: "Jose Paez", githubUsername: "regionativo", imageName: "regionativo", imageExtension: "jpg"),
    Sponsor(name: "Petar Shomov", githubUsername: "pshomov", imageName: "pshomov", imageExtension: "jpg"),
    Sponsor(name: "Michael Künneke", githubUsername: "mkuennek", imageName: "mkuennek", imageExtension: "jpg"),
    Sponsor(name: "Nick Nisi", githubUsername: "nicknisi", imageName: "nicknisi", imageExtension: "png"),
    Sponsor(name: "Maciej", githubUsername: "c0desurfer", imageName: "c0desurfer", imageExtension: "jpg"),
    Sponsor(name: "Josh Taylor", githubUsername: "joshbtay", imageName: "joshbtay", imageExtension: "jpg"),
    Sponsor(name: "Matheus Gomes", githubUsername: "matgomes", imageName: "matgomes", imageExtension: "jpg"),
    Sponsor(name: "stevenshrago", githubUsername: "stevenshrago", imageName: "stevenshrago", imageExtension: "png")
]

private func rankLabel(for index: Int) -> String {
    NumberFormatter.localizedString(from: NSNumber(value: index + 1), number: .ordinal)
}

private func openURL(_ string: String) {
    guard let url = URL(string: string) else { return }
    NSWorkspace.shared.open(url)
}

private let sponsorColumnWidth: CGFloat = 760

struct SponsorsView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var motionPolicy: MotionPolicy
    @State private var appeared = false
    let onClose: () -> Void

    private var sparkleGradient: LinearGradient {
        LinearGradient(
            colors: [.yellow, .orange],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var body: some View {
        ZStack {
            AuroraBackdrop(motionPolicy: motionPolicy)

            contentVStack
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 480, minHeight: 440)
        .background(.ultraThinMaterial.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .scaleEffect(appeared ? 1.0 : 0.98)
        .opacity(appeared ? 1.0 : 0.0)
        .onAppear {
            if motionPolicy.animationsEnabled {
                withAnimation(.easeOut(duration: 0.2)) {
                    appeared = true
                }
            } else {
                appeared = true
            }
        }
        .onChange(of: motionPolicy.animationsEnabled) { _, enabled in
            if !enabled {
                appeared = true
            }
        }
    }

    private var contentVStack: some View {
        VStack(spacing: 16) {
            headerSection

            CompanySponsorsRow(motionPolicy: motionPolicy)
                .padding(.horizontal, 28)

            SupporterScroll(motionPolicy: motionPolicy)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            footerSection
        }
        .padding(.vertical, 22)
    }

    private var headerSection: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 22))
                    .foregroundStyle(sparkleGradient)
                    .symbolEffect(.pulse, options: .repeating, isActive: motionPolicy.animationsEnabled)
                Text("Omni Sponsors")
                    .font(.system(size: 26, weight: .bold))
                Image(systemName: "sparkles")
                    .font(.system(size: 22))
                    .foregroundStyle(sparkleGradient)
                    .symbolEffect(.pulse, options: .repeating, isActive: motionPolicy.animationsEnabled)
            }

            Text("Thank you to our amazing supporters!")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)

            Button(action: { openURL("https://github.com/sponsors/BarutSRB") }, label: {
                Label("Become a Sponsor", systemImage: "heart.fill")
                    .font(.system(size: 13, weight: .semibold))
            })
            .buttonStyle(OmniGlassButtonStyle(isProminent: true))
            .accessibilityLabel("Become a sponsor on GitHub")
        }
        .padding(.horizontal, 28)
    }

    private var footerSection: some View {
        VStack(spacing: 8) {
            Button(action: onClose) {
                Text("Close")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 80)
            }
            .buttonStyle(OmniGlassButtonStyle())

            Text("Ranks reflect sponsorship order, not donation amounts")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 28)
    }
}

private struct CompanySponsorsRow: View {
    @Bindable var motionPolicy: MotionPolicy

    private static let blacksmithLogo = Bundle.module.url(forResource: "blacksmith", withExtension: "png")
        .flatMap(NSImage.init(contentsOf:))

    var body: some View {
        if motionPolicy.animationsEnabled {
            TimelineView(.animation) { context in
                row(time: context.date.timeIntervalSinceReferenceDate)
            }
        } else {
            row(time: 0)
        }
    }

    private func row(time: Double) -> some View {
        HStack(spacing: 16) {
            CompanySponsorCard(
                motionPolicy: motionPolicy,
                time: time,
                title: Text(verbatim: "Blacksmith"),
                actionLabel: Text(verbatim: "blacksmith.sh"),
                accessibilityName: Text(verbatim: "Blacksmith.sh"),
                url: "https://www.blacksmith.sh/",
                logo: Self.blacksmithLogo
            )

            ForEach(0 ..< 2, id: \.self) { _ in
                CompanySponsorCard(
                    motionPolicy: motionPolicy,
                    time: time,
                    title: Text("Reserved for company sponsors"),
                    actionLabel: Text("Become a sponsor"),
                    accessibilityName: Text("Reserved for company sponsors — become a sponsor"),
                    url: "https://github.com/sponsors/BarutSRB"
                )
            }
        }
        .frame(maxWidth: sponsorColumnWidth)
        .frame(maxWidth: .infinity)
    }
}

private struct CompanySponsorCard: View {
    @Bindable var motionPolicy: MotionPolicy
    let time: Double
    let title: Text
    let actionLabel: Text
    let accessibilityName: Text
    let url: String
    var logo: NSImage?

    private static let borderColors: [Color] = [
        Color(white: 0.85),
        Color(white: 0.5),
        Color(white: 0.85)
    ]

    var body: some View {
        Button(action: { openURL(url) }, label: {
            cardContent
        })
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityName)
    }

    @ViewBuilder private var cardIcon: some View {
        if let logo {
            Image(nsImage: logo)
                .resizable()
                .scaledToFit()
                .frame(width: 42)
                .clipShape(.rect(cornerRadius: 8))
        } else {
            Image(systemName: "building.2.crop.circle")
                .font(.system(size: 42))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
        }
    }

    private var cardContent: some View {
        VStack(spacing: 10) {
            cardIcon
                .frame(height: 42)

            title
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2, reservesSpace: true)
                .minimumScaleFactor(0.8)

            HStack(spacing: 4) {
                actionLabel
                Image(systemName: "arrow.up.right")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .padding(.horizontal, 16)
        .omniGlassEffect(in: RoundedRectangle(cornerRadius: 22))
        .overlay(AnimatedBorder(motionPolicy: motionPolicy, colors: Self.borderColors, time: time))
    }
}

struct SupporterScroll: View {
    @Bindable var motionPolicy: MotionPolicy

    var body: some View {
        SponsorAutoScrollList(
            animationsEnabled: motionPolicy.animationsEnabled,
            speed: 18,
            spacing: 16
        ) {
            grid
                .frame(maxWidth: sponsorColumnWidth)
                .frame(maxWidth: .infinity)
        }
        .mask(edgeFade)
    }

    private var grid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 150), spacing: 16)],
            spacing: 16
        ) {
            ForEach(Array(sponsors.enumerated()), id: \.element.id) { index, sponsor in
                SponsorCardView(
                    motionPolicy: motionPolicy,
                    name: sponsor.name,
                    githubUsername: sponsor.githubUsername,
                    imageName: sponsor.imageName,
                    imageExtension: sponsor.imageExtension,
                    creditMessage: sponsor.creditMessage,
                    tier: .standard,
                    rankLabel: rankLabel(for: index)
                )
            }
        }
    }

    private var edgeFade: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0.0),
                .init(color: .black, location: 0.05),
                .init(color: .black, location: 0.95),
                .init(color: .clear, location: 1.0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}
