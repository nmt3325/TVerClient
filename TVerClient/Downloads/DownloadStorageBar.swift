import SwiftUI

/// Capacity bar shown in the download settings: saved episodes, everything
/// else on the volume, and the space that is still free.
///
/// 「保存済み / その他 / 空き」の 3 分割を 1 本で表す標準部品は無いので、バーは
/// 自前のまま残す。ただし塗りにはシステムの fill 色だけを使い、区切り線のための
/// 色（`DS.Palette.separator`）を面積の塗りに流用しない。凡例は標準の
/// `LabeledContent` に寄せる。
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
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    segment(DS.Palette.downloaded, width: proxy.size.width * usedFraction)
                    segment(DS.Palette.capacityOther, width: proxy.size.width * otherFraction)
                    segment(DS.Palette.capacityFree, width: proxy.size.width * freeFraction)
                }
            }
            .frame(height: 10)
            .clipShape(Capsule())

            VStack(spacing: DS.Spacing.xs) {
                legend(
                    DS.Palette.downloaded,
                    title: Vocabulary.Library.downloads,
                    bytes: usage.usedBytes
                )
                legend(DS.Palette.capacityOther, title: "その他", bytes: otherBytes)
                legend(DS.Palette.capacityFree, title: "空き", bytes: usage.availableBytes)
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
        LabeledContent {
            Text(Self.formatted(bytes))
        } label: {
            HStack(spacing: DS.Spacing.xs) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(title)
            }
        }
        .font(.footnote)
    }

    private var spokenSummary: String {
        let used = Self.formatted(usage.usedBytes)
        let other = Self.formatted(otherBytes)
        let free = Self.formatted(usage.availableBytes)
        return "端末の容量。\(Vocabulary.Library.downloads) \(used)、その他 \(other)、空き \(free)"
    }

    static func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }
}
