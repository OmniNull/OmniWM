// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import SwiftUI

@MainActor
struct SystemStatsView: View {
    static let preferredSize = CGSize(width: 340, height: 300)

    let model: SystemStatsModel

    var body: some View {
        Group {
            if let snapshot = model.snapshot {
                dashboard(snapshot)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(16)
        .frame(width: Self.preferredSize.width, height: Self.preferredSize.height, alignment: .top)
        .omniGlassEffect(in: RoundedRectangle(cornerRadius: 14))
    }

    private func dashboard(_ snapshot: SystemStatsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header(snapshot)
            metricGrid(snapshot)
            footer(snapshot.host)
        }
    }

    private func header(_ snapshot: SystemStatsSnapshot) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "applelogo")
                .font(.system(size: 22, weight: .semibold))
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.host.hostname)
                    .font(.headline)
                    .lineLimit(1)
                Text(snapshot.host.chip)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(Self.uptimeText(snapshot.uptime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func metricGrid(_ snapshot: SystemStatsSnapshot) -> some View {
        let memoryFraction = Self.fraction(used: snapshot.ramUsedBytes, total: snapshot.ramTotalBytes)
        let diskFraction = Self.fraction(
            used: UInt64(max(snapshot.diskUsedBytes, 0)),
            total: UInt64(max(snapshot.diskTotalBytes, 0))
        )
        return Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                SystemStatsMetricTile(
                    title: String(localized: "CPU"),
                    systemImage: "cpu",
                    value: Self.percentText(snapshot.cpuUsage),
                    detail: snapshot
                        .cpuUsage == nil ? String(localized: "Waiting for delta") :
                        String(localized: "Total processor"),
                    fraction: snapshot.cpuUsage,
                    tint: .cyan
                )
                SystemStatsMetricTile(
                    title: String(localized: "GPU"),
                    systemImage: "gpu",
                    value: Self.percentText(snapshot.gpuUtilization),
                    detail: snapshot
                        .gpuUtilization == nil ? String(localized: "Unavailable") :
                        String(localized: "Device utilization"),
                    fraction: snapshot.gpuUtilization,
                    tint: .purple
                )
            }
            GridRow {
                SystemStatsMetricTile(
                    title: String(localized: "Memory"),
                    systemImage: "memorychip",
                    value: Self.percentText(memoryFraction),
                    detail: Self.memoryText(snapshot),
                    fraction: memoryFraction,
                    tint: .green
                )
                SystemStatsMetricTile(
                    title: String(localized: "Disk"),
                    systemImage: "internaldrive",
                    value: Self.percentText(diskFraction),
                    detail: Self.diskText(snapshot),
                    fraction: diskFraction,
                    tint: .orange
                )
            }
        }
    }

    private func footer(_ host: SystemStatsHostInfo) -> some View {
        let displayText = host.resolutions.isEmpty ? String(localized: "Display data unavailable") : host.resolutions
            .joined(separator: "  ")
        return VStack(alignment: .leading, spacing: 2) {
            Text(host.modelIdentifier)
                .font(.caption.weight(.medium))
                .lineLimit(1)
            Text("\(host.osVersion)  \(displayText)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.tail)
        }
    }

    nonisolated static func fraction(used: UInt64, total: UInt64) -> Double? {
        guard total > 0 else { return nil }
        return min(max(Double(used) / Double(total), 0), 1)
    }

    nonisolated static func percentText(_ fraction: Double?) -> String {
        guard let fraction else { return "—" }
        return fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    nonisolated static func uptimeText(_ uptime: TimeInterval) -> String {
        let total = Int(uptime)
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 {
            return String(localized: "\(days)d \(hours)h \(minutes)m")
        }
        if hours > 0 {
            return String(localized: "\(hours)h \(minutes)m")
        }
        return String(localized: "\(minutes)m")
    }

    private static func memoryText(_ snapshot: SystemStatsSnapshot) -> String {
        let used = ByteCountFormatter.string(fromByteCount: Int64(snapshot.ramUsedBytes), countStyle: .memory)
        let total = ByteCountFormatter.string(fromByteCount: Int64(snapshot.ramTotalBytes), countStyle: .memory)
        if let pressure = snapshot.memoryPressure {
            return String(localized: "\(used) / \(total) · \(pressure.displayName)")
        }
        return String(localized: "\(used) / \(total)")
    }

    private static func diskText(_ snapshot: SystemStatsSnapshot) -> String {
        let used = ByteCountFormatter.string(fromByteCount: snapshot.diskUsedBytes, countStyle: .file)
        let free = ByteCountFormatter.string(
            fromByteCount: max(snapshot.diskTotalBytes - snapshot.diskUsedBytes, 0),
            countStyle: .file
        )
        return String(localized: "\(used) used · \(free) free")
    }
}

@MainActor
private struct SystemStatsMetricTile: View {
    let title: String
    let systemImage: String
    let value: String
    let detail: String
    let fraction: Double?
    let tint: Color

    private var tileShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 14)
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(value)
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.1))
                    if let fraction {
                        Capsule()
                            .fill(tint.gradient)
                            .frame(width: max(4, proxy.size.width * min(max(fraction, 0), 1)))
                    }
                }
            }
            .frame(height: 6)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 76, maxHeight: 76, alignment: .topLeading)
        .background(.thinMaterial, in: tileShape)
        .overlay {
            tileShape.strokeBorder(Color.secondary.opacity(0.16), lineWidth: 0.75)
        }
    }
}
