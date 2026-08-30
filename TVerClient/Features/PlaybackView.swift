import AVKit
import SwiftUI

/// Episode player screen.
///
/// The video and its controls are one fixed stage at the top of the screen and
/// only the programme information scrolls, so the transport controls can never
/// scroll away or fight the scroll gesture again.
@MainActor
struct PlaybackView: View {
    let program: TVerProgram
    @ObservedObject var playbackController: PlaybackController
    @EnvironmentObject private var downloadCenter: DownloadCenter
    @ObservedObject var libraryStore: ProgramLibraryStore
    @StateObject private var pictureInPicture = PictureInPictureCoordinator()
    @StateObject private var chrome = PlayerChromeModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var isFullScreenPresented = false

    init(
        program: TVerProgram,
        playbackController: PlaybackController,
        libraryStore: ProgramLibraryStore
    ) {
        self.program = program
        self.playbackController = playbackController
        self.libraryStore = libraryStore
    }

    private var isCurrent: Bool { playbackController.currentProgram?.id == program.id }
    /// 横向き。ここで番組情報まで縦に積むと、映像とコントロールが画面外へ出る。
    private var isCompactHeight: Bool { verticalSizeClass == .compact }
    private var isFavorite: Bool { libraryStore.isFavorite(program) }
    private var shareItem: ProgramShareItem { ProgramShareItem(program: program) }

    private var relatedPrograms: [TVerProgram] {
        Array(libraryStore.recentPrograms.filter { $0.id != program.id }.prefix(6))
    }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                VStack(spacing: 0) {
                    stage
                        .frame(width: proxy.size.width, height: stageHeight(in: proxy.size))
                    // 横向きでは映像とコントロールだけを残す。番組情報を積むと、
                    // その分だけ操作系が画面の下へ押し出されて届かなくなる。
                    if !isCompactHeight { details }
                }
            }
            .background(Color(uiColor: .systemBackground))
            .navigationTitle("視聴")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: ToolbarCompat.leading) {
                    DownloadButton(program: program)
                }
                ToolbarItem(placement: ToolbarCompat.trailing) {
                    // 「閉じる」だけだと停止と読み違えられる。止める操作と画面を
                    // 畳む操作を、名前のとおりに別々に置く。
                    HStack(spacing: DS.Spacing.xs) {
                        Button {
                            playbackController.stop()
                            dismiss()
                        } label: {
                            Image(systemName: "stop.fill")
                                .frame(
                                    minWidth: DS.Size.minimumTapTarget,
                                    minHeight: DS.Size.minimumTapTarget
                                )
                        }
                        .accessibilityLabel("再生を停止して閉じる")

                        Button("最小化") { dismiss() }
                            .frame(
                                minWidth: DS.Size.minimumTapTarget,
                                minHeight: DS.Size.minimumTapTarget
                            )
                            .accessibilityLabel("最小化")
                            .accessibilityHint("再生は続きます。画面下のバーから停止できます")
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            // 停止したときに Picture in Picture の小窓だけが生き残らないよう、
            // この画面が持っている調整役を再生側へ預ける。
            playbackController.bindPictureInPicture(pictureInPicture)
        }
        .task(id: program.id) {
            libraryStore.recordRecentlyViewed(program)
            // 最小化して開き直しただけなら、最初からに戻さず続きを見せる。
            guard !playbackController.isLoaded(program) else { return }
            await playbackController.play(program)
        }
        // Finishing an episode retires its download so the library can offer to
        // free the space back up.
        .onChange(of: playbackController.state) { state in
            guard isCurrent, state == .ended else { return }
            downloadCenter.markWatched(program.id)
        }
        .fullScreenCover(isPresented: $isFullScreenPresented) {
            FullScreenPlaybackView(
                playbackController: playbackController,
                pictureInPicture: pictureInPicture,
                title: program.seriesTitle,
                subtitle: program.title,
                accessibilityLabel: "\(program.seriesTitle)の全画面動画プレイヤー",
                onExit: { isFullScreenPresented = false }
            )
        }
    }

    private var stage: some View {
        PlayerStage(
            playbackController: playbackController,
            pictureInPicture: pictureInPicture,
            model: chrome,
            title: program.seriesTitle,
            subtitle: program.title,
            accessibilityLabel: "\(program.seriesTitle)の動画プレイヤー",
            supportsSeeking: true,
            isFullScreen: false,
            isActiveSurface: !isFullScreenPresented,
            showsContinuityNotice: isCompactHeight,
            onToggleFullScreen: { isFullScreenPresented = true }
        )
    }

    /// 縦向きは 16:9。ただし画面の6割強を超えない。横向きは全面。
    private func stageHeight(in size: CGSize) -> CGFloat {
        guard !isCompactHeight else { return size.height }
        return min((size.width * 9 / 16).rounded(), (size.height * 0.62).rounded())
    }

    private var details: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.l) {
                header
                actionRow
                statusSection
                if !relatedPrograms.isEmpty { relatedSection }
            }
            .padding(DS.Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Text(program.title)
                .font(.title3.bold())
                .fixedSize(horizontal: false, vertical: true)
            Text(program.seriesTitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: DS.Spacing.m) {
                Label(program.broadcastLabel, systemImage: "clock")
                if let availableUntil = program.availableUntil, !availableUntil.isEmpty {
                    Label(availableUntil, systemImage: "calendar.badge.clock")
                }
            }
            .font(DS.Typography.rowDetail)
            .foregroundStyle(.secondary)
            if !program.description.isEmpty {
                Text(program.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actionRow: some View {
        HStack(spacing: DS.Spacing.s) {
            Button { libraryStore.toggleFavorite(program) } label: {
                Label(
                    isFavorite ? "お気に入り済み" : "お気に入り",
                    systemImage: isFavorite ? "heart.fill" : "heart"
                )
                .frame(maxWidth: .infinity, minHeight: DS.Size.minimumTapTarget)
            }
            .buttonStyle(.bordered)
            .tint(isFavorite ? .red : .accentColor)
            .accessibilityLabel(isFavorite ? "お気に入りから削除" : "お気に入りに追加")

            ShareLink(
                item: shareItem.url,
                subject: Text(shareItem.subject),
                message: Text(shareItem.message)
            ) {
                Image(systemName: "square.and.arrow.up")
                    .frame(minWidth: DS.Size.minimumTapTarget, minHeight: DS.Size.minimumTapTarget)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("共有")

            Button { openURL(program.webURL) } label: {
                Image(systemName: "safari")
                    .frame(minWidth: DS.Size.minimumTapTarget, minHeight: DS.Size.minimumTapTarget)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("TVer公式ページで開く")
        }
        .controlSize(.large)
    }

    @ViewBuilder
    private var statusSection: some View {
        if isCurrent, let presentation = playbackController.errorPresentation {
            PlaybackFailureView(presentation: presentation, officialURL: program.webURL) {
                libraryStore.recordRecentlyViewed(program)
                Task { await playbackController.play(program) }
            }
        } else if isCurrent, let notice = playbackController.continuityNotice {
            // 縦向きの映像は小さく、重ねると再生コントロールを埋めてしまう。
            PlaybackContinuityNoticeView(
                notice: notice,
                recover: { playbackController.recoverFromContinuityNotice() },
                dismissNotice: { playbackController.dismissContinuityNotice() }
            )
        } else if isCurrent, playbackController.state == .ended {
            Label("再生が終了しました", systemImage: "checkmark.circle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var relatedSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Text("最近見た番組")
                .font(DS.Typography.sectionHeader)
                .foregroundStyle(.secondary)
            ForEach(relatedPrograms, id: \.id) { item in
                MediaRow(
                    title: item.title,
                    subtitle: item.seriesTitle,
                    detail: item.broadcastLabel,
                    thumbnailURL: item.thumbnailURL
                ) {
                    EmptyView()
                }
                .padding(.vertical, DS.Spacing.xxs)
                Divider().overlay(DS.Palette.separator)
            }
        }
    }
}
