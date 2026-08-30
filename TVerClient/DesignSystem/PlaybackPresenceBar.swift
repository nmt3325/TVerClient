import SwiftUI

/// タブの上に常駐する「いま鳴っているもの」のバー。
///
/// 再生シートを閉じたあとに停止する場所がアプリ内に一つも無いという状態を
/// 塞ぐ。再生を保持している間は必ずどこかのタブにこれが見えていること。
struct PlaybackPresenceBar: View {
    let presence: PlaybackPresence
    let onToggle: () -> Void
    let onStop: () -> Void
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: DS.Spacing.s) {
            Button(action: onOpen) {
                HStack(spacing: DS.Spacing.s) {
                    if presence.isLive {
                        MediaBadge(.live)
                    }
                    VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                        Text(presence.title)
                            .font(DS.Typography.rowTitle)
                            .lineLimit(1)
                        if !presence.subtitle.isEmpty {
                            Text(presence.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("再生画面を開く。\(presence.title)")

            Button(action: onToggle) {
                Image(systemName: presence.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: DS.Size.minimumTapTarget, height: DS.Size.minimumTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(presence.isPlaying ? "一時停止" : "再生")

            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .frame(width: DS.Size.minimumTapTarget, height: DS.Size.minimumTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("再生を停止")
        }
        .padding(.leading, DS.Spacing.l)
        .frame(minHeight: DS.Size.minimumTapTarget + DS.Spacing.s)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
