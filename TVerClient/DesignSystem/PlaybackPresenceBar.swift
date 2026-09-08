import SwiftUI

/// Persistent playback access above, never on top of, the system tab bar.
struct PlaybackPresenceBar: View {
    let presence: PlaybackPresence
    let onToggle: () -> Void
    let onStop: () -> Void
    let onOpen: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    openButton
                    HStack {
                        Spacer(minLength: 0)
                        transport
                    }
                }
            } else {
                HStack(spacing: DS.Spacing.s) {
                    openButton
                    transport
                }
            }
        }
        .padding(.horizontal, DS.Spacing.l)
        .padding(.vertical, DS.Spacing.xs)
        .frame(minHeight: DS.Size.minimumTapTarget + DS.Spacing.s)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var openButton: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text(presence.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
                    .multilineTextAlignment(.leading)
                if !presence.subtitle.isEmpty {
                    Text(presence.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                }
            }
            .frame(maxWidth: .infinity, minHeight: DS.Size.minimumTapTarget, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("再生画面を開く。\(presence.title)")
        .accessibilityValue(presence.subtitle)
        .accessibilityIdentifier("playback.presence.open")
    }

    @ViewBuilder
    private var transport: some View {
        Button(action: onToggle) {
            Image(systemName: presence.isPlaying ? "pause.fill" : "play.fill")
                .font(.body.weight(.semibold))
                .frame(width: DS.Size.minimumTapTarget, height: DS.Size.minimumTapTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(presence.isPlaying ? "一時停止" : "再生")
        .accessibilityIdentifier("playback.presence.toggle")

        Button(action: onStop) {
            Image(systemName: "stop.fill")
                .frame(width: DS.Size.minimumTapTarget, height: DS.Size.minimumTapTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("再生を停止")
        .accessibilityHint("映像と音声の再生を終了します")
        .accessibilityIdentifier("playback.presence.stop")
    }
}
