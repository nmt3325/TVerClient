import AVFoundation
import SwiftUI

struct PlaybackFailureView: View {
    let presentation: TVerErrorPresentation
    let officialURL: URL
    let retry: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(presentation.title, systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(presentation.message)
                .font(.subheadline)
            Text(presentation.recoverySuggestion)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button(action: retry) {
                Label("もう一度試す", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Button { openURL(officialURL) } label: {
                Label("TVer公式ページで開く", systemImage: "safari")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

struct PlaybackTimelineView: View {
    @ObservedObject var playbackController: PlaybackController

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let elapsed = safeElapsed
            if let duration = safeDuration {
                VStack(spacing: 6) {
                    Slider(
                        value: Binding(
                            get: { min(elapsed, duration) },
                            set: { playbackController.seek(to: $0) }
                        ),
                        in: 0 ... duration
                    )
                    .accessibilityLabel(TVerAccessibilityText.playbackTime(elapsed: elapsed, duration: duration))
                    HStack {
                        Text(formattedDuration(elapsed))
                        Spacer()
                        Text(formattedDuration(duration))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                }
            } else {
                Text(TVerAccessibilityText.playbackTime(elapsed: elapsed, duration: nil))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .accessibilityLabel(TVerAccessibilityText.playbackTime(elapsed: elapsed, duration: nil))
            }
        }
    }

    private var safeElapsed: TimeInterval {
        let elapsed = playbackController.player.currentTime().seconds
        return elapsed.isFinite ? max(0, elapsed) : 0
    }

    private var safeDuration: TimeInterval? {
        guard let duration = playbackController.player.currentItem?.duration.seconds,
              duration.isFinite,
              duration > 0
        else { return nil }
        return duration
    }

    private func formattedDuration(_ value: TimeInterval) -> String {
        let total = max(0, Int(value.rounded()))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

@MainActor
struct PlaybackVideoSurface: View {
    let player: AVPlayer
    @ObservedObject var pictureInPicture: PictureInPictureCoordinator
    let accessibilityLabel: String
    var cornerRadius: CGFloat = 12
    var videoGravity: AVLayerVideoGravity = .resizeAspect
    /// The inline surface releases the shared player layer while the full
    /// screen surface is presented, so playback is never restarted.
    var isActiveSurface: Bool = true
    /// When set, a full screen button and a double tap gesture are offered.
    var onEnterFullScreen: (() -> Void)? = nil

    var body: some View {
        PlayerLayerView(
            player: player,
            pictureInPicture: pictureInPicture,
            videoGravity: videoGravity,
            isActiveSurface: isActiveSurface
        )
        .frame(maxWidth: .infinity)
        .aspectRatio(16 / 9, contentMode: .fit)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityLabel(accessibilityLabel)
        .overlay(alignment: .bottomTrailing) { fullScreenButton }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onEnterFullScreen?() }
    }

    @ViewBuilder
    private var fullScreenButton: some View {
        if let onEnterFullScreen {
            Button(action: onEnterFullScreen) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.black.opacity(0.55), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("全画面")
            .accessibilityHint("動画を画面いっぱいに表示します")
            .accessibilityIdentifier(PlaybackAccessibilityIdentifier.fullScreenEnter)
            .padding(6)
        }
    }
}

@MainActor
struct PictureInPictureControl: View {
    @ObservedObject var coordinator: PictureInPictureCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: togglePictureInPicture) {
                Label(buttonTitle, systemImage: buttonSystemImage)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(!isEnabled)
            .accessibilityLabel(buttonTitle)
            .accessibilityValue(statusDescription)
            .accessibilityHint(accessibilityHint)

            if let errorMessage = coordinator.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityLabel("ピクチャ・イン・ピクチャのエラー。\(errorMessage)")
            }
        }
    }

    private var isEnabled: Bool {
        switch coordinator.state {
        case .active:
            return true
        case .starting, .stopping:
            return false
        case .inactive, .failed:
            return coordinator.availability == .available
        }
    }

    private var buttonTitle: String {
        switch coordinator.state {
        case .active, .stopping:
            return "ピクチャ・イン・ピクチャを終了"
        case .starting:
            return "ピクチャ・イン・ピクチャを開始中"
        case .inactive, .failed:
            return "ピクチャ・イン・ピクチャを開始"
        }
    }

    private var buttonSystemImage: String {
        switch coordinator.state {
        case .active, .stopping:
            return "pip.exit"
        case .inactive, .starting, .failed:
            return "pip.enter"
        }
    }

    private var statusDescription: String {
        switch coordinator.state {
        case .active:
            return "使用中"
        case .starting:
            return "開始中"
        case .stopping:
            return "終了中"
        case .failed:
            return "開始できませんでした"
        case .inactive:
            switch coordinator.availability {
            case .available:
                return "利用可能"
            case .unavailable:
                return "再生準備中"
            case .unsupported:
                return "このデバイスでは利用できません"
            }
        }
    }

    private var accessibilityHint: String {
        if coordinator.state == .active {
            return "動画をアプリ内のプレイヤーに戻します"
        }
        return "ほかのアプリを使用しながら動画を小さいウインドウで再生します"
    }

    private func togglePictureInPicture() {
        if coordinator.isActive {
            coordinator.stop()
        } else {
            coordinator.start()
        }
    }
}
