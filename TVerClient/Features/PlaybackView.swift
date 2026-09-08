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
    @EnvironmentObject private var seriesSubscriptions: SeriesSubscriptionStore
    @ObservedObject var libraryStore: ProgramLibraryStore
    @StateObject private var pictureInPicture = PictureInPictureCoordinator()
    @StateObject private var chrome = PlayerChromeModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var isFullScreenPresented = false
    @State private var confirmsUnsubscribe = false
    @ScaledMetric(relativeTo: .subheadline) private var minimumStageHeight: CGFloat = 180

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

    /// この画面は自分で NavigationStack を持たない。push 先で入れ子になると
    /// 検索欄を持つタブでは再生に入った瞬間に落ちる。シートで出す側が包む。
    var body: some View {
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
            // 戻る操作は NavigationStack に任せる。画面を離れることと停止を
            // 同じ場所に並べず、番組への追加操作だけを一つのメニューにまとめる。
            ToolbarItem(placement: ToolbarCompat.trailing) {
                Menu {
                    ShareLink(
                        item: shareItem.url,
                        subject: Text(shareItem.subject),
                        message: Text(shareItem.message)
                    ) { Label("番組を共有", systemImage: "square.and.arrow.up") }
                    Button { openURL(program.webURL) } label: {
                        Label("TVer公式ページで開く", systemImage: "safari")
                    }
                    Divider()
                    Button {
                        guard isCurrent else { return }
                        playbackController.stop()
                        dismiss()
                    } label: {
                        Label("再生を停止して閉じる", systemImage: "stop.fill")
                    }
                    .disabled(!isCurrent)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .frame(minWidth: DS.Size.minimumTapTarget, minHeight: DS.Size.minimumTapTarget)
                }
                .accessibilityLabel("番組の操作")
                .accessibilityHint("共有、公式ページ、再生の停止")
            }
        }
        .onAppear {
            // 停止したときに Picture in Picture の小窓だけが生き残らないよう、
            // この画面が持っている調整役を再生側へ預ける。
            playbackController.bindPictureInPicture(pictureInPicture)
        }
        .onDisappear {
            // 画面を離れたら預けたものを返す。別の画面が預け直したあとなら何もしない。
            playbackController.unbindPictureInPicture(pictureInPicture)
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

    /// 通常は16:9。大きい文字では時間表示の余白を確保するが、
    /// 番組情報も読めるよう画面の6割強を上限にする。横向きは全面。
    private func stageHeight(in size: CGSize) -> CGFloat {
        guard !isCompactHeight else { return size.height }
        return min(max((size.width * 9 / 16).rounded(), minimumStageHeight), (size.height * 0.62).rounded())
    }

    private var details: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.l) {
                // 回復の操作を説明文や購読設定の下へ埋めない。
                statusSection
                header
                actionRow
                seriesSubscriptionRow
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
                .fixedSize(horizontal: false, vertical: true)
            // 長い放送日時と配信期限を競合させず、大きい文字でも全文を読める。
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Label(program.broadcastLabel, systemImage: "clock")
                if let availableUntil = program.availableUntil, !availableUntil.isEmpty {
                    Label(availableUntil, systemImage: "calendar.badge.clock")
                }
            }
            .font(DS.Typography.rowDetail)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
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
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            HStack(spacing: DS.Spacing.s) {
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    Text("この話のダウンロード")
                        .font(.subheadline.weight(.semibold))
                    Text(downloadStatus)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                DownloadButton(program: program)
            }
            .padding(.horizontal, DS.Spacing.m)
            .padding(.vertical, DS.Spacing.xs)
            .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.medium))

            Button { libraryStore.toggleFavorite(program) } label: {
                Label(
                    isFavorite ? "お気に入り済み" : "お気に入りに追加",
                    systemImage: isFavorite ? "heart.fill" : "heart"
                )
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: DS.Size.minimumTapTarget)
            }
            .buttonStyle(.bordered)
            .tint(isFavorite ? .red : .accentColor)
            .accessibilityLabel(isFavorite ? "お気に入りから削除" : "お気に入りに追加")
        }
        .controlSize(.large)
    }

    private var downloadStatus: String {
        switch downloadCenter.state(for: program.id) {
        case .notDownloaded: return "保存するとオフラインでも視聴できます"
        case .queued: return "ダウンロード待ち"
        case let .downloading(progress):
            return "ダウンロード中・\(Int((DownloadCenter.clamp(progress) * 100).rounded()))%"
        case .paused:
            return downloadCenter.isInterrupted(program.id)
                ? "一時停止中・続きから再開できないため、再ダウンロードが必要です"
                : "一時停止中・右のボタンから再開できます"
        case .failed: return "保存できませんでした・右のボタンから再試行できます"
        case .downloaded: return "保存済み・オフラインで視聴できます"
        }
    }

    @ViewBuilder
    private var seriesSubscriptionRow: some View {
        if let seriesID = program.seriesID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !seriesID.isEmpty
        {
            let isSubscribed = seriesSubscriptions.isSubscribed(seriesID: seriesID)
            let activity = seriesSubscriptions.activity(for: seriesID)
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Button {
                    if isSubscribed {
                        confirmsUnsubscribe = true
                    } else {
                        Task { await seriesSubscriptions.subscribe(to: program) }
                    }
                } label: {
                    HStack(spacing: DS.Spacing.s) {
                        if activity?.isBusy == true {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: isSubscribed ? "arrow.down.circle.fill" : "arrow.down.circle")
                        }
                        Text(isSubscribed ? "新着の自動ダウンロードを停止" : "新着を自動ダウンロード")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(isSubscribed ? "ON" : "OFF")
                            .font(.caption.bold())
                    }
                    .frame(maxWidth: .infinity, minHeight: DS.Size.minimumTapTarget)
                }
                .buttonStyle(.bordered)
                .tint(isSubscribed ? DS.Palette.catchUp : .accentColor)
                .confirmationDialog(
                    "新着の自動ダウンロードを停止しますか？",
                    isPresented: $confirmsUnsubscribe,
                    titleVisibility: .visible
                ) {
                    Button("自動ダウンロードを停止", role: .destructive) {
                        seriesSubscriptions.unsubscribe(seriesID: seriesID)
                    }
                    Button("キャンセル", role: .cancel) {}
                } message: {
                    Text("このシリーズの新着は自動保存されなくなります。保存済み・ダウンロード中の番組は削除されません。")
                }
                .accessibilityLabel(
                    "\(program.seriesTitle)の新着自動ダウンロードを\(isSubscribed ? "オフ" : "オン")にする"
                )
                .accessibilityHint(
                    isSubscribed
                        ? "購読を解除しても、保存済みの番組は残ります"
                        : "現在配信中の話は基準にするだけで、今後公開された新着だけを保存します"
                )

                if let text = seriesActivityText(activity) {
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(activityIsFailure(activity) ? DS.Palette.warning : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(text)
                }
            }
        }
    }

    private func seriesActivityText(_ activity: SeriesSubscriptionActivity?) -> String? {
        switch activity {
        case .none:
            return "単話のダウンロードとは別の設定です。"
        case .waitingForBaseline:
            return "購読中です。次回オンライン時に現在の配信話を基準にします。"
        case .baselining:
            return "現在の配信話を確認中です。既存話は自動ダウンロードしません。"
        case .checking:
            return "購読中の新着を確認しています。"
        case .subscribed:
            return "購読開始後に公開された新着だけを自動ダウンロードします。"
        case let .failed(message):
            return "購読は継続中です。基準の取得に失敗しました: \(message)"
        }
    }

    private func activityIsFailure(_ activity: SeriesSubscriptionActivity?) -> Bool {
        if case .failed = activity { return true }
        return false
    }

    @ViewBuilder
    private var statusSection: some View {
        if isCurrent, let presentation = playbackController.errorPresentation {
            PlaybackFailureView(presentation: presentation, officialURL: program.webURL) {
                libraryStore.recordRecentlyViewed(program)
                Task {
                    guard isCurrent else { return }
                    let action = PlayerPrimaryAction.resolve(using: playbackController)
                    await action.perform(using: playbackController)
                }
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
