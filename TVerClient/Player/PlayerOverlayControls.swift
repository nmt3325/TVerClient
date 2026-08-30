import AVFoundation
import SwiftUI

/// Everything drawn on top of the video: title row, transport, scrubber and
/// the settings menu. Shared by the inline and the full screen player so both
/// behave the same way.
@MainActor
struct PlayerOverlayControls: View {
    @ObservedObject var playbackController: PlaybackController
    @ObservedObject var pictureInPicture: PictureInPictureCoordinator
    @ObservedObject var model: PlayerChromeModel
    let title: String
    var subtitle: String?
    var supportsSeeking: Bool = true
    var isFullScreen: Bool = false
    var onToggleFullScreen: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: DS.Spacing.s)
            transportRow
            Spacer(minLength: DS.Spacing.s)
            bottomBar
        }
        .padding(.horizontal, isFullScreen ? DS.Spacing.xl : DS.Spacing.m)
        .padding(.vertical, DS.Spacing.s)
        .background(PlayerScrim())
        .tint(.white)
        .foregroundStyle(.white)
    }

    // MARK: - Top

    private var topBar: some View {
        HStack(alignment: .top, spacing: DS.Spacing.xs) {
            if isFullScreen {
                PlayerIconButton(
                    systemImage: "chevron.down",
                    label: "全画面を閉じる",
                    identifier: PlaybackAccessibilityIdentifier.fullScreenExit
                ) { onToggleFullScreen?() }
                titleStack
            }
            Spacer(minLength: 0)
            if isFullScreen {
                PlayerIconButton(
                    systemImage: model.videoGravitySystemImage,
                    label: model.videoGravityTitle,
                    identifier: PlaybackAccessibilityIdentifier.fullScreenGravity
                ) { model.toggleVideoGravity() }
            }
            AirPlayRouteButton()
                .frame(width: DS.Size.minimumTapTarget, height: DS.Size.minimumTapTarget)
                .accessibilityLabel("AirPlay")
            pictureInPictureButton
            settingsMenu
        }
    }

    private var titleStack: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, DS.Spacing.s)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var pictureInPictureButton: some View {
        if pictureInPicture.availability != .unsupported {
            PlayerIconButton(
                systemImage: pictureInPicture.isActive
                    ? "pip.exit"
                    : "pip.enter",
                label: pictureInPicture.isActive ? "ピクチャインピクチャを終了" : "ピクチャインピクチャ",
                isEnabled: pictureInPicture.isActive || pictureInPicture.canStart
            ) {
                model.registerInteraction()
                if pictureInPicture.isActive {
                    pictureInPicture.stop()
                } else {
                    pictureInPicture.start()
                }
            }
        }
    }

    private var settingsMenu: some View {
        Menu {
            Picker("再生速度", selection: speedBinding) {
                ForEach(PlaybackSpeed.allCases) { speed in
                    Text(speed.title).tag(speed)
                }
            }
            if !playbackController.subtitleOptions.isEmpty {
                Picker("字幕", selection: subtitleBinding) {
                    ForEach(playbackController.subtitleOptions) { option in
                        Text(option.title).tag(option.id)
                    }
                }
            }
            if playbackController.audioOptions.count > 1 {
                Picker("音声", selection: audioBinding) {
                    ForEach(playbackController.audioOptions) { option in
                        Text(option.title).tag(option.id)
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: DS.Size.minimumTapTarget, height: DS.Size.minimumTapTarget)
                .contentShape(Circle())
        }
        .accessibilityLabel("再生設定")
        .simultaneousGesture(TapGesture().onEnded { model.registerInteraction() })
    }

    // MARK: - Center

    private var transportRow: some View {
        HStack(spacing: DS.Spacing.xl) {
            PlayerIconButton(
                systemImage: "gobackward.10",
                label: "10秒戻す",
                glyphSize: 24,
                diameter: 52,
                isEnabled: supportsSeeking
            ) {
                model.registerInteraction()
                playbackController.seek(by: -10)
            }
            PlayerIconButton(
                systemImage: playbackController.isPlaying ? "pause.fill" : "play.fill",
                label: playbackController.isPlaying ? "一時停止" : "再生",
                identifier: isFullScreen ? PlaybackAccessibilityIdentifier.fullScreenPlayPause : nil,
                glyphSize: 30,
                diameter: 64,
                isProminent: true
            ) {
                model.registerInteraction()
                playbackController.togglePlayback()
            }
            PlayerIconButton(
                systemImage: "goforward.10",
                label: "10秒送る",
                glyphSize: 24,
                diameter: 52,
                isEnabled: supportsSeeking
            ) {
                model.registerInteraction()
                playbackController.seek(by: 10)
            }
        }
    }

    // MARK: - Bottom

    private var bottomBar: some View {
        HStack(alignment: .center, spacing: DS.Spacing.m) {
            VStack(spacing: 2) {
                if supportsSeeking {
                    PlaybackScrubber(
                        elapsed: playbackController.currentTime,
                        duration: playbackController.duration ?? 0,
                        bufferedFraction: playbackController.loadedFraction,
                        isEnabled: playbackController.canSeek,
                        onScrubStarted: {
                            model.registerInteraction()
                            playbackController.beginScrubbing()
                        },
                        onScrubChanged: { playbackController.previewScrub(to: $0) },
                        onScrubEnded: {
                            playbackController.endScrubbing(at: $0)
                            model.registerInteraction()
                        },
                        onAdjust: { playbackController.seek(by: $0) }
                    )
                    timeLabels
                } else {
                    liveLabel
                }
            }
            if let onToggleFullScreen {
                PlayerIconButton(
                    systemImage: isFullScreen
                        ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right",
                    label: isFullScreen ? "全画面を閉じる" : "全画面",
                    identifier: isFullScreen ? nil : PlaybackAccessibilityIdentifier.fullScreenEnter,
                    glyphSize: 15
                ) {
                    model.registerInteraction()
                    onToggleFullScreen()
                }
            }
        }
    }

    private var timeLabels: some View {
        HStack {
            Text(ScrubberMath.formattedTime(playbackController.currentTime))
            Spacer(minLength: 0)
            Text(
                ScrubberMath.remainingText(
                    elapsed: playbackController.currentTime,
                    duration: playbackController.duration ?? 0
                )
            )
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.white.opacity(0.8))
        .accessibilityHidden(true)
    }

    private var liveLabel: some View {
        HStack(spacing: DS.Spacing.xs) {
            Circle()
                .fill(DS.Palette.live)
                .frame(width: 8, height: 8)
            Text("LIVE")
                .font(.caption.weight(.bold))
            Spacer(minLength: 0)
        }
        .frame(height: DS.Size.minimumTapTarget)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("ライブ配信中")
    }

    // MARK: - Bindings

    private var speedBinding: Binding<PlaybackSpeed> {
        Binding(
            get: { playbackController.playbackSpeed },
            set: { newValue in
                model.registerInteraction()
                playbackController.setPlaybackSpeed(newValue)
            }
        )
    }

    private var subtitleBinding: Binding<String> {
        Binding(
            get: { playbackController.subtitleOptions.first(where: { $0.isSelected })?.id ?? MediaSelectionEntry.offIdentifier },
            set: { newValue in
                model.registerInteraction()
                playbackController.selectSubtitle(id: newValue)
            }
        )
    }

    private var audioBinding: Binding<String> {
        Binding(
            get: { playbackController.audioOptions.first(where: { $0.isSelected })?.id ?? "" },
            set: { newValue in
                model.registerInteraction()
                playbackController.selectAudio(id: newValue)
            }
        )
    }
}
