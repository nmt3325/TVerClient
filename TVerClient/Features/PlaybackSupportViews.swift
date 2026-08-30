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

/// Standalone timeline for surfaces that do not overlay their controls.
///
/// The old implementation wrapped a `Slider` in `TimelineView(.periodic(by: 1))`,
/// which rebuilt the slider under the finger every second and made seeking
/// impossible. It now draws the shared scrubber and commits a single seek.
struct PlaybackTimelineView: View {
    @ObservedObject var playbackController: PlaybackController

    var body: some View {
        VStack(spacing: DS.Spacing.xs) {
            PlaybackScrubber(
                elapsed: playbackController.currentTime,
                duration: playbackController.duration ?? 0,
                bufferedFraction: playbackController.loadedFraction,
                isEnabled: playbackController.canSeek,
                onScrubStarted: { playbackController.beginScrubbing() },
                onScrubChanged: { playbackController.previewScrub(to: $0) },
                onScrubEnded: { playbackController.endScrubbing(at: $0) },
                onAdjust: { playbackController.seek(by: $0) }
            )
            HStack {
                Text(ScrubberMath.formattedTime(playbackController.currentTime))
                Spacer()
                Text(durationText)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
    }

    private var durationText: String {
        guard let duration = playbackController.duration else { return "--:--" }
        return ScrubberMath.formattedTime(duration)
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
