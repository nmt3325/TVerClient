import SwiftUI

/// Capacity bar shown above the offline library: saved episodes, everything
/// else on the volume, and the space that is still free.
@MainActor
struct DownloadStorageBar: View {
    let usage: DownloadStorageUsage

    @State private var deviceTotalBytes: Int64 = 0

    init(usage: DownloadStorageUsage) {
        self.usage = usage
    }

    private var totalBytes: Int64 { max(deviceTotalBytes, usage.totalBytes) }

    private var otherBytes: Int64 {
        max(0, totalBytes - usage.usedBytes - usage.availableBytes)
    }

    private var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(usage.usedBytes) / Double(totalBytes))
    }

    private var freeFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1 - usedFraction, Double(usage.availableBytes) / Double(totalBytes))
    }

    private var otherFraction: Double { max(0, 1 - usedFraction - freeFraction) }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    segment(DS.Palette.downloaded, width: proxy.size.width * usedFraction)
                    segment(Color.secondary.opacity(0.35), width: proxy.size.width * otherFraction)
                    segment(DS.Palette.separator, width: proxy.size.width * freeFraction)
                }
            }
            .frame(height: 10)
            .clipShape(Capsule())

            HStack(alignment: .top, spacing: DS.Spacing.l) {
                legend(DS.Palette.downloaded, title: "ダウンロード済み", bytes: usage.usedBytes)
                legend(Color.secondary.opacity(0.35), title: "その他", bytes: otherBytes)
                legend(DS.Palette.separator, title: "空き", bytes: usage.availableBytes)
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, DS.Spacing.xs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenSummary)
        .onAppear {
            if deviceTotalBytes == 0 {
                deviceTotalBytes = DownloadCenter.deviceTotalCapacity()
            }
        }
    }

    private func segment(_ color: Color, width: CGFloat) -> some View {
        Rectangle()
            .fill(color)
            .frame(width: max(0, width))
    }

    private func legend(_ color: Color, title: String, bytes: Int64) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.xs) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(Self.formatted(bytes))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.primary)
            }
        }
    }

    private var spokenSummary: String {
        let used = Self.formatted(usage.usedBytes)
        let other = Self.formatted(otherBytes)
        let free = Self.formatted(usage.availableBytes)
        return "保存容量、ダウンロード済み \(used)、その他 \(other)、空き \(free)"
    }

    static func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }
}
