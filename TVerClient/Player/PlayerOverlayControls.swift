import AVFoundation
import SwiftUI
import UIKit

/// A non-interactive hierarchy marker placed beneath a SwiftUI button. Scrubber
/// input is owned by `PlaybackScrubberInteractionView`; a passive marker must
/// never become a second touch consumer in front of a SwiftUI gesture.
@MainActor
final class PlayerControlHitTargetView: UIView {
    static let playPauseIdentifier = "playback.hit-target.play-pause"
    static let failureRetryIdentifier = "playback.hit-target.failure-retry"
    static let failureDetailsIdentifier = "playback.hit-target.failure-details"

    init(identifier: String) {
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        isAccessibilityElement = false
        isUserInteractionEnabled = false
        accessibilityIdentifier = identifier
    }

    required init?(coder: NSCoder) {
        preconditionFailure("PlayerControlHitTargetView is created in code only")
    }
}

@MainActor
private struct PlayerControlHitTarget: UIViewRepresentable {
    let identifier: String

    func makeUIView(context: Context) -> PlayerControlHitTargetView {
        PlayerControlHitTargetView(identifier: identifier)
    }

    func updateUIView(_ view: PlayerControlHitTargetView, context: Context) {
        view.accessibilityIdentifier = identifier
        view.isUserInteractionEnabled = false
    }
}

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
    /// 中断の告知を映像の上に重ねるかどうか。
    var showsContinuityNotice: Bool = true
    /// 画面の安全領域。ノッチやホームインジケータの上に操作系を
    /// 寄せないよう、固定の余白ではなくこれを見て詰める。
    var safeAreaInsets = EdgeInsets()
    var onToggleFullScreen: (() -> Void)?
    var onBackgroundSingleTap: () -> Void = {}
    var onBackgroundDoubleTap: (CGPoint) -> Void = { _ in }
    @State private var showsFailureDetails = false

    // Keep the existing call surface independent from private presentation state.
    init(
        playbackController: PlaybackController,
        pictureInPicture: PictureInPictureCoordinator,
        model: PlayerChromeModel,
        title: String,
        subtitle: String? = nil,
        supportsSeeking: Bool = true,
        isFullScreen: Bool = false,
        showsContinuityNotice: Bool = true,
        safeAreaInsets: EdgeInsets = EdgeInsets(),
        onToggleFullScreen: (() -> Void)? = nil,
        onBackgroundSingleTap: @escaping () -> Void = {},
        onBackgroundDoubleTap: @escaping (CGPoint) -> Void = { _ in }
    ) {
        self.playbackController = playbackController
        self.pictureInPicture = pictureInPicture
        self.model = model
        self.title = title
        self.subtitle = subtitle
        self.supportsSeeking = supportsSeeking
        self.isFullScreen = isFullScreen
        self.showsContinuityNotice = showsContinuityNotice
        self.safeAreaInsets = safeAreaInsets
        self.onToggleFullScreen = onToggleFullScreen
        self.onBackgroundSingleTap = onBackgroundSingleTap
        self.onBackgroundDoubleTap = onBackgroundDoubleTap
    }

    var body: some View {
        GeometryReader { proxy in
            let layout = PlayerControlLayout(
                availableWidth: proxy.size.width - chromeInsets.leading - chromeInsets.trailing,
                availableHeight: proxy.size.height - chromeInsets.top - chromeInsets.bottom,
                isFullScreen: isFullScreen
            )
            ZStack {
                PlayerScrim()
                controlStack(layout: layout)
                    .backgroundPreferenceValue(PlayerControlHitRegionsKey.self) { anchors in
                        GeometryReader { hitProxy in
                            PlayerBackgroundTapSurface(
                                onSingleTap: onBackgroundSingleTap,
                                onDoubleTap: onBackgroundDoubleTap,
                                excludedRects: anchors.map { hitProxy[$0] },
                                isEnabled: model.areControlsVisible
                            )
                            .accessibilityHidden(true)
                        }
                    }
            }
        }
        .tint(.white)
        .foregroundStyle(.white)
        .sheet(isPresented: $showsFailureDetails) {
            if let presentation = playbackController.errorPresentation {
                PlayerFailureDetailsSheet(
                    presentation: presentation,
                    action: primaryAction,
                    officialURL: playbackController.currentProgram?.webURL ?? playbackController.currentLiveChannel?.webURL
                ) {
                    showsFailureDetails = false
                    activatePrimaryAction()
                }
            }
        }
        // スクラブが onScrubEnded を伴わずに終わる経路がある（別のジェスチャに奪われた、
        // 途中で画面が閉じた）。掴んだ印をそこだけで落としていると、自動非表示が
        // 止まったまま操作パネルが出っぱなしになる。
        .task(id: playbackController.isScrubbing) {
            guard !playbackController.isScrubbing else { return }
            await Task.yield()
            guard !Task.isCancelled, !playbackController.isScrubbing else { return }
            model.endHeldInteraction()
        }
    }

    private func controlStack(layout: PlayerControlLayout) -> some View {
        VStack(spacing: 0) {
            topBar(separatesTitle: layout.separatesTitle)
                .accessibilitySortPriority(4)
            Spacer(minLength: layout.compactTransport ? 0 : DS.Spacing.s)
            // 停止理由と回復ボタンがあるときは、無意味な再生ボタンを重ねない。
            if showsContinuityNotice, playbackController.continuityNotice != nil {
                continuityBanner
                    .accessibilitySortPriority(3)
            } else if playbackController.errorPresentation != nil {
                failureRecoveryRow
                    .accessibilitySortPriority(3)
            } else {
                transportRow(layout: layout)
                    .accessibilitySortPriority(2)
            }
            Spacer(minLength: layout.compactTransport ? 0 : DS.Spacing.s)
            bottomBar
                .accessibilitySortPriority(1)
        }
        .accessibilityElement(children: .contain)
        .padding(chromeInsets)
    }

    /// 固定の余白と安全領域の大きいほうを採る。横向きではノッチ側だけ
    /// 余白が増えるので、左右で違う値になるのが正しい。
    private var chromeInsets: EdgeInsets {
        let horizontal = isFullScreen ? DS.Spacing.xl : DS.Spacing.m
        let vertical = DS.Spacing.s
        return EdgeInsets(
            top: max(vertical, safeAreaInsets.top),
            leading: max(horizontal, safeAreaInsets.leading + DS.Spacing.xs),
            bottom: max(vertical, safeAreaInsets.bottom),
            trailing: max(horizontal, safeAreaInsets.trailing + DS.Spacing.xs)
        )
    }

    // MARK: - Top

    private func topBar(separatesTitle: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: DS.Spacing.xs) {
                if isFullScreen {
                    PlayerIconButton(
                        systemImage: "chevron.down",
                        label: "全画面を閉じる",
                        identifier: PlaybackAccessibilityIdentifier.fullScreenExit
                    ) { onToggleFullScreen?() }
                    if !separatesTitle { titleStack }
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
                    .playerControlHitRegion()
                pictureInPictureButton
                settingsMenu
            }
            if separatesTitle { titleStack }
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
            HStack(spacing: DS.Spacing.xs) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 17, weight: .semibold))
                if !isFullScreen {
                    Text("設定")
                        .font(.subheadline.weight(.semibold))
                }
            }
            .foregroundStyle(.white)
            .frame(minWidth: DS.Size.minimumTapTarget, minHeight: DS.Size.minimumTapTarget)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("再生設定：速度・字幕・音声")
        .accessibilityHint("再生速度や利用可能な字幕・音声を選べます")
        .simultaneousGesture(TapGesture().onEnded { model.registerInteraction() })
        .playerControlHitRegion()
    }

    // MARK: - Continuity

    /// 勝手に止まった理由と、次の一手。映像が十分に大きい面（全画面や
    /// 横向き）ではここに出す。黙って音が消えたままにしないための表示。
    @ViewBuilder
    private var continuityBanner: some View {
        if showsContinuityNotice, let notice = playbackController.continuityNotice {
            HStack(alignment: .center, spacing: DS.Spacing.s) {
                VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                    Text(notice.title)
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                    Text(notice.nextStep)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button {
                    model.registerInteraction()
                    playbackController.recoverFromContinuityNotice()
                } label: {
                    Label(notice.actionTitle, systemImage: notice.actionSystemImage)
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, DS.Spacing.m)
                        .frame(minHeight: DS.Size.minimumTapTarget)
                        .background(Color.white.opacity(0.22), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .playerControlHitRegion()
                PlayerIconButton(
                    systemImage: "xmark",
                    label: "この案内を閉じる",
                    glyphSize: 13
                ) {
                    playbackController.dismissContinuityNotice()
                }
            }
            .padding(.horizontal, DS.Spacing.m)
            .padding(.vertical, DS.Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                    .fill(Color.black.opacity(0.6))
            )
            .padding(.bottom, DS.Spacing.s)
            .accessibilityElement(children: .contain)
        }
    }

    // MARK: - Center

    private var primaryAction: PlayerPrimaryAction {
        PlayerPrimaryAction.resolve(using: playbackController)
    }

    private func activatePrimaryAction() {
        model.registerInteraction()
        let action = primaryAction
        Task { await action.perform(using: playbackController) }
    }

    private var failureRecoveryRow: some View {
        HStack(spacing: DS.Spacing.s) {
            Text(playbackController.errorPresentation?.title ?? "再生できませんでした")
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            PlayerIconButton(systemImage: "info.circle", label: "再生エラーの詳細") {
                model.registerInteraction()
                showsFailureDetails = true
            }
            .background(PlayerControlHitTarget(identifier: PlayerControlHitTargetView.failureDetailsIdentifier))
            Button(action: activatePrimaryAction) {
                Label(primaryAction.title, systemImage: primaryAction.systemImage)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, DS.Spacing.s)
                    .frame(minHeight: DS.Size.minimumTapTarget)
                    .background(Color.white.opacity(0.22), in: Capsule())
                    .contentShape(Capsule())
            }
            // A bordered style adds padding outside the 44pt label and can
            // overflow the 180pt stage; own that background inside the target.
            .buttonStyle(.plain)
            .disabled(!primaryAction.isEnabled)
            .accessibilityHint("現在の番組の再生をもう一度試します")
            .playerControlHitRegion()
            .background(PlayerControlHitTarget(identifier: PlayerControlHitTargetView.failureRetryIdentifier))
        }
        .padding(.horizontal, DS.Spacing.s)
        .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: DS.Radius.medium))
    }

    private func transportRow(layout: PlayerControlLayout) -> some View {
        HStack(spacing: layout.transportSpacing) {
            if supportsSeeking {
                PlayerIconButton(
                    systemImage: "gobackward.10",
                    label: "10秒戻す",
                    glyphSize: 24,
                    diameter: layout.skipDiameter,
                    isEnabled: playbackController.canSeek
                ) {
                    model.registerInteraction()
                    playbackController.seek(by: -10)
                }
            }
            PlayerIconButton(
                systemImage: primaryAction.systemImage,
                label: primaryAction.title,
                identifier: isFullScreen ? PlaybackAccessibilityIdentifier.fullScreenPlayPause : nil,
                glyphSize: layout.compactTransport ? 24 : 30,
                diameter: layout.playDiameter,
                isProminent: true,
                isEnabled: primaryAction.isEnabled
            ) { activatePrimaryAction() }
            .background(
                PlayerControlHitTarget(identifier: PlayerControlHitTargetView.playPauseIdentifier)
            )
            if supportsSeeking {
                PlayerIconButton(
                    systemImage: "goforward.10",
                    label: "10秒送る",
                    glyphSize: 24,
                    diameter: layout.skipDiameter,
                    isEnabled: playbackController.canSeek
                ) {
                    model.registerInteraction()
                    playbackController.seek(by: 10)
                }
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
                            // 指を離すまで自動非表示を止める。掴んでいる最中に
                            // シークバーごと消えるのが最悪の体験だった。
                            model.beginHeldInteraction()
                            playbackController.beginScrubbing()
                        },
                        onScrubChanged: { playbackController.previewScrub(to: $0) },
                        onScrubEnded: {
                            playbackController.endScrubbing(at: $0)
                            model.endHeldInteraction()
                        },
                        onScrubCancelled: {
                            playbackController.cancelScrubbing()
                            model.endHeldInteraction()
                        },
                        onAdjust: { playbackController.seek(by: $0) }
                    )
                    .playerControlHitRegion()
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
        .font(.subheadline.monospacedDigit())
        .foregroundStyle(.white.opacity(0.8))
        // 残り時間は「あと何分見られるか」の判断に必要なので、読み上げから
        // 外さない。数字の羅列は聴いて分からないので、日本語に開いた文にする。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(timeAccessibilityLabel)
    }

    /// 「1分30秒経過、残り58分30秒」。尺が未定のときは経過だけを読む。
    private var timeAccessibilityLabel: String {
        let elapsed = playbackController.currentTime
        let elapsedText = "\(ScrubberMath.spokenTime(elapsed))経過"
        guard let duration = playbackController.duration, duration.isFinite, duration > 0 else {
            return elapsedText
        }
        return "\(elapsedText)、残り\(ScrubberMath.spokenTime(max(0, duration - elapsed)))"
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
