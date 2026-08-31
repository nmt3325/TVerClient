import SwiftUI

/// 一覧の上に固定で出す鮮度・更新失敗の告知。
///
/// 引き下げ更新が失敗してもスピナーが消えるだけだと、古い一覧を最新だと
/// 信じ続けてしまう。一覧を持つ画面は全部これをリストの上に置く。
struct FreshnessBanner: View {
    let freshness: LoadFreshness
    var retry: (() -> Void)?

    var body: some View {
        if freshness.isDegraded {
            HStack(alignment: .top, spacing: DS.Spacing.s) {
                Image(systemName: icon)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(DS.Palette.warning)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                    Text(freshness.headline)
                        .font(.footnote.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                if let retry {
                    Button("再試行", action: retry)
                        .font(.footnote.weight(.semibold))
                        .frame(minWidth: DS.Size.minimumTapTarget, minHeight: DS.Size.minimumTapTarget)
                }
            }
            .padding(.horizontal, DS.Spacing.l)
            .padding(.vertical, DS.Spacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
            .accessibilityElement(children: .combine)
        }
    }

    private var icon: String {
        switch freshness {
        case .fresh: return "checkmark.circle"
        case let .cached(_, reason): return reason == .offline ? "wifi.slash" : "exclamationmark.triangle.fill"
        case .refreshFailed: return "exclamationmark.triangle.fill"
        }
    }

    private var detail: String? {
        switch freshness {
        case .fresh:
            return nil
        case let .cached(at, reason):
            return "\(Self.timestamp(at)) 時点の内容です。\(reason.recovery)"
        case let .refreshFailed(lastGoodAt, message, recovery):
            var parts: [String] = []
            if !message.isEmpty { parts.append(message) }
            if let lastGoodAt { parts.append("表示中の内容は \(Self.timestamp(lastGoodAt)) 時点です。") }
            if let recovery, !recovery.isEmpty { parts.append(recovery) }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = BroadcastDay.timeZone
        formatter.dateFormat = "M月d日 H:mm"
        return formatter.string(from: date)
    }
}
