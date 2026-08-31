import SwiftUI

/// Download-first library. Grouped lists for the transfers in flight, the saved
/// episodes, the kept programmes and the history, plus the notices that must
/// never be swallowed.
///
/// 一覧の上には鮮度とお知らせを必ず置く。保存済みが消えたことも、転送が中断した
/// ことも、ここで言葉にしなければ利用者は気づけないまま番組を失う。
///
/// 部品は iOS 標準に寄せている。行は `NavigationLink` の push、見出しは標準の
/// `Section(header:footer:)`、永続する設定は `Form` のシート、鮮度の帯は
/// `.safeAreaInset(edge: .top)`。自前のカード帯とタップジェスチャは使わない。
@MainActor
struct LibraryView: View {
    @ObservedObject var libraryStore: ProgramLibraryStore
    @ObservedObject var playbackController: PlaybackController
    @EnvironmentObject private var downloadCenter: DownloadCenter
    @EnvironmentObject private var seriesSubscriptions: SeriesSubscriptionStore
    @EnvironmentObject private var tabReselection: TabReselection

    @State private var pendingAction: PendingDestructiveAction?
    @State private var pendingUnsubscribe: SeriesSubscription?
    @State private var activeSheet: LibrarySheet?
    @State private var selection: Set<LibraryRowID> = []

    /// 取り返しのつかない操作は、経路にかかわらずこの入れ物を通して確認する。
    private struct PendingDestructiveAction: Identifiable {
        let id = UUID()
        let confirmation: DownloadConfirmation
        let perform: () -> Void
    }

    /// 編集モードの選択キー。同じ番組が保存済みとマイリストの両方に並ぶので、
    /// 番組IDだけを鍵にすると片方を選んだだけで両方が選ばれてしまう。
    private enum LibraryRowID: Hashable {
        case subscription(String)
        case transfer(String)
        case saved(String)
        case favorite(String)
        case recent(String)
    }

    /// ツールバーから開くモーダルは1つの状態にまとめる。同じ画面に `.sheet` を
    /// 並べると、あとから足した方が開かなくなる。
    private enum LibrarySheet: String, Identifiable {
        case settings
        case diagnostics

        var id: String { rawValue }
    }

    init(libraryStore: ProgramLibraryStore, playbackController: PlaybackController) {
        self.libraryStore = libraryStore
        self.playbackController = playbackController
    }

    private var inFlight: [DownloadRecord] {
        downloadCenter.records.filter { record in !record.state.isFinished }
    }

    private var saved: [DownloadRecord] {
        downloadCenter.records.filter { record in record.state.isFinished }
    }

    private var isEmpty: Bool {
        downloadCenter.records.isEmpty
            && seriesSubscriptions.subscriptions.isEmpty
            && libraryStore.favoritePrograms.isEmpty
            && libraryStore.recentPrograms.isEmpty
    }

    private var hasNotices: Bool {
        Self.shouldShowNotices(
            hasDownloadNotices: !downloadCenter.notices.isEmpty,
            hasDownloadRejection: downloadCenter.lastRejection != nil,
            didRecoverFromCorruptedLibraryStorage: libraryStore.didRecoverFromCorruptedStorage,
            libraryPersistenceFailure: libraryStore.lastPersistenceFailure,
            seriesPersistenceFailure: seriesSubscriptions.lastPersistenceFailure
        )
    }

    /// 断られた\(Vocabulary.Download.action)は一度きりの確認なので `.alert` に出す。
    /// 一覧に残すお知らせが1件も無いときに空のセクションを作らないための判定。
    private var hasNoticeRows: Bool {
        hasNotices
            && (!downloadCenter.notices.isEmpty
                || libraryStore.didRecoverFromCorruptedStorage
                || libraryStore.lastPersistenceFailure != nil
                || seriesSubscriptions.lastPersistenceFailure != nil)
    }

    static func shouldShowNotices(
        hasDownloadNotices: Bool,
        hasDownloadRejection: Bool,
        didRecoverFromCorruptedLibraryStorage: Bool,
        libraryPersistenceFailure: String?,
        seriesPersistenceFailure: String?
    ) -> Bool {
        hasDownloadNotices
            || hasDownloadRejection
            || didRecoverFromCorruptedLibraryStorage
            || libraryPersistenceFailure != nil
            || seriesPersistenceFailure != nil
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                libraryList
                    .onReceive(tabReselection.events) { tab in
                        // 表示中のタブをもう一度選んだら先頭へ戻る。iOS 標準の動き。
                        guard tab == .library else { return }
                        withAnimation {
                            proxy.scrollTo(StandardScrollAnchor.top, anchor: .top)
                        }
                    }
            }
            .navigationTitle("ライブラリ")
            .navigationDestination(for: TVerProgram.self) { program in
                playbackDestination(for: program)
            }
            .toolbar { libraryToolbar }
            .confirmationDialog(
                Text(pendingAction?.confirmation.title ?? ""),
                isPresented: Binding(
                    get: { pendingAction != nil },
                    set: { isPresented in
                        if !isPresented { pendingAction = nil }
                    }
                ),
                titleVisibility: .visible,
                presenting: pendingAction
            ) { action in
                Button(
                    action.confirmation.confirmLabel,
                    role: action.confirmation.isDestructive ? ButtonRole.destructive : nil
                ) {
                    action.perform()
                    pendingAction = nil
                }
                Button("やめる", role: .cancel) { pendingAction = nil }
            } message: { action in
                Text(action.confirmation.message)
            }
            .alert(
                "自動ダウンロードを解除しますか？",
                isPresented: Binding(
                    get: { pendingUnsubscribe != nil },
                    set: { isPresented in
                        if !isPresented { pendingUnsubscribe = nil }
                    }
                ),
                presenting: pendingUnsubscribe
            ) { subscription in
                Button("購読解除", role: .destructive) {
                    seriesSubscriptions.unsubscribe(seriesID: subscription.seriesID)
                    pendingUnsubscribe = nil
                }
                Button("やめる", role: .cancel) { pendingUnsubscribe = nil }
            } message: { subscription in
                Text("「\(subscription.seriesTitle)」の今後の新着を停止します。保存済み・ダウンロード中の番組は残ります。")
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .settings:
                LibraryDownloadSettingsView(downloadCenter: downloadCenter)
            case .diagnostics:
                DiagnosticsView(logStore: DiagnosticLogStore.shared)
            }
        }
        .onAppear { downloadCenter.refreshStorage() }
    }

    private var libraryList: some View {
        List(selection: $selection) {
            scrollAnchor
            noticeSection
            sections
        }
        .listStyle(.plain)
        .refreshable {
            downloadCenter.refreshStorage()
            await seriesSubscriptions.refreshAll(
                downloads: downloadCenter,
                forceRefresh: true
            )
        }
        .alert(
            "\(Vocabulary.Download.action)を始められませんでした",
            isPresented: rejectionPresentation,
            presenting: downloadCenter.lastRejection
        ) { rejection in
            if let retryOnCellular = cellularOverride(for: rejection) {
                Button(
                    "今回だけモバイル通信で\(Vocabulary.Download.action)",
                    action: retryOnCellular
                )
            }
            Button("閉じる", role: .cancel) { downloadCenter.clearRejection() }
        } message: { rejection in
            Text(rejectionMessage(rejection))
        }
        .safeAreaInset(edge: .top, spacing: 0) { freshnessBanner }
    }

    /// 鮮度の帯は一覧の行ではなく画面上端に固定する。行にすると標準のインセットと
    /// 区切り線を自前で打ち消すことになる。
    @ViewBuilder
    private var freshnessBanner: some View {
        if downloadCenter.freshness.isDegraded {
            FreshnessBanner(
                freshness: downloadCenter.freshness,
                retry: { downloadCenter.refreshStorage() }
            )
        }
    }

    /// 先頭へ戻るための目印。iOS 16 には `.scrollPosition` が無いので、高さ 0 の
    /// 行を先頭に置いて `ScrollViewReader` からここへ戻す。
    private var scrollAnchor: some View {
        Color.clear
            .frame(height: 0)
            .id(StandardScrollAnchor.top)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var sections: some View {
        if isEmpty {
            Section {
                ContentStatusView(.empty(
                    title: "\(Vocabulary.Library.downloads)の番組はありません",
                    message: "番組の右にある\(Vocabulary.Download.action)ボタンを押すと、通信のない場所でも見られます。",
                    systemImage: "arrow.down.circle"
                ))
            }
        } else {
            seriesSubscriptionsSection
            downloadingSection
            savedSection
            favoritesSection
            recentsSection
        }
    }

    private func playbackDestination(for program: TVerProgram) -> some View {
        // `PlaybackView` は自前の `NavigationStack` を持つ（t3 所有）。push 先に
        // そのまま置くとナビゲーションバーが二段になるので、外側を隠して内側の
        // 「停止」「最小化」だけを残す。t3 側が自前の `NavigationStack` を外したら、
        // この 1 行も同時に外すこと。
        PlaybackView(
            program: program,
            playbackController: playbackController,
            libraryStore: libraryStore
        )
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            DiagnosticLogStore.shared.record(
                .info,
                category: "library",
                message: "Library row opened for playback"
            )
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var libraryToolbar: some ToolbarContent {
        ToolbarItem(placement: ToolbarCompat.trailing) {
            if !isEmpty { EditButton() }
        }
        ToolbarItem(placement: ToolbarCompat.trailing) {
            Menu {
                // 永続する設定は `Form` の画面に集める。メニューにはその場で
                // 終わる操作だけを残す。
                Button {
                    activeSheet = .settings
                } label: {
                    Label("\(Vocabulary.Download.action)の設定", systemImage: "gearshape")
                }
                Divider()
                Button {
                    downloadCenter.refreshStorage()
                } label: {
                    Label("空き容量を再計算", systemImage: "arrow.clockwise")
                }
                // 診断画面への入口はここが唯一の経路。消さないこと。
                Button {
                    activeSheet = .diagnostics
                } label: {
                    Label("通信診断とログ", systemImage: "stethoscope")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("その他の操作")
        }
        ToolbarItemGroup(placement: .bottomBar) {
            if !selection.isEmpty {
                Spacer()
                Button("選択した\(selection.count)件を削除", role: .destructive) {
                    requestSelectionRemoval()
                }
            }
        }
    }

    // MARK: - Notices

    @ViewBuilder
    private var noticeSection: some View {
        if hasNoticeRows {
            Section {
                ForEach(downloadCenter.notices) { notice in
                    noticeRow(
                        systemImage: notice.kind.systemImage,
                        message: notice.message,
                        recovery: notice.recovery,
                        actionLabel: notice.action.label,
                        action: handler(for: notice.action),
                        dismiss: { downloadCenter.dismissNotice(notice.id) }
                    )
                }

                if libraryStore.didRecoverFromCorruptedStorage {
                    noticeRow(
                        systemImage: "arrow.counterclockwise.circle",
                        message: "\(Vocabulary.Library.favorites)と\(Vocabulary.Library.history)の保存データが壊れていたため、読み直しました。",
                        recovery: "一部が消えている場合があります。足りない番組はもう一度追加してください。",
                        actionLabel: nil,
                        action: nil,
                        dismiss: { libraryStore.acknowledgeStorageRecovery() }
                    )
                }

                if let failure = libraryStore.lastPersistenceFailure {
                    noticeRow(
                        systemImage: "exclamationmark.triangle.fill",
                        message: failure,
                        recovery: "次に起動したとき\(Vocabulary.Library.favorites)が元に戻る場合があります。\(Vocabulary.Library.history)を減らすと保存しやすくなります。",
                        actionLabel: clearRecentsAction() == nil
                            ? nil
                            : "\(Vocabulary.Library.history)をすべて消す",
                        action: clearRecentsAction(),
                        dismiss: { libraryStore.acknowledgePersistenceFailure() }
                    )
                }

                if let failure = seriesSubscriptions.lastPersistenceFailure {
                    noticeRow(
                        systemImage: "exclamationmark.triangle.fill",
                        message: failure,
                        recovery: "次回起動時に以前の購読状態へ戻る場合があります。通信状態ではなく端末内保存の問題です。",
                        actionLabel: nil,
                        action: nil,
                        dismiss: { seriesSubscriptions.acknowledgePersistenceFailure() }
                    )
                    .accessibilityIdentifier("library.notice.series-persistence")
                }
            } header: {
                Text("お知らせ")
            }
        }
    }

    /// お知らせは標準の行として並べ、閉じる操作はスワイプと長押しに逃がす。
    /// 自前の帯と閉じるボタンを行の中に描くのはやめた。
    private func noticeRow(
        systemImage: String,
        message: String,
        recovery: String?,
        actionLabel: String?,
        action: (() -> Void)?,
        dismiss: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Label {
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: systemImage)
                    .symbolRenderingMode(.hierarchical)
            }
            .font(.footnote)

            if let recovery = recovery {
                Text(recovery)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let actionLabel = actionLabel, let action = action {
                Button(actionLabel, action: action)
                    .font(.footnote.weight(.semibold))
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(action: dismiss) {
                Label("このお知らせを閉じる", systemImage: "xmark")
            }
        }
        .contextMenu {
            if let actionLabel = actionLabel, let action = action {
                Button(actionLabel, action: action)
            }
            Button(action: dismiss) {
                Label("このお知らせを閉じる", systemImage: "xmark")
            }
        }
    }

    private var rejectionPresentation: Binding<Bool> {
        Binding(
            get: { downloadCenter.lastRejection != nil },
            set: { isPresented in
                if !isPresented { downloadCenter.clearRejection() }
            }
        )
    }

    private func rejectionMessage(_ rejection: DownloadCenter.Rejection) -> String {
        [rejection.message, rejection.recovery]
            .compactMap { $0 }
            .joined(separator: "\n")
    }

    private func handler(for action: DownloadNotice.Action) -> (() -> Void)? {
        switch action {
        case .none:
            return nil
        case let .restart(programIDs, _):
            return { downloadCenter.restartAll(programIDs) }
        case let .resumeOnCellular(programIDs, _):
            return { downloadCenter.resumeAllAllowingCellular(programIDs) }
        }
    }

    private func cellularOverride(for rejection: DownloadCenter.Rejection) -> (() -> Void)? {
        guard rejection.canRetryOnCellular, let program = rejection.program else { return nil }
        return {
            downloadCenter.clearRejection()
            downloadCenter.start(program, allowingCellular: true)
        }
    }

    private func clearRecentsAction() -> (() -> Void)? {
        guard !libraryStore.recentPrograms.isEmpty else { return nil }
        return { requestClearRecents() }
    }

    // MARK: - Sections

    @ViewBuilder
    private var seriesSubscriptionsSection: some View {
        if !seriesSubscriptions.subscriptions.isEmpty {
            Section {
                if seriesSubscriptions.refreshState.isRefreshing {
                    ProgressView("購読シリーズの新着を確認中")
                }

                ForEach(seriesSubscriptions.subscriptions) { subscription in
                    seriesSubscriptionRow(subscription)
                        .tag(LibraryRowID.subscription(subscription.seriesID))
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            unsubscribeButton(subscription)
                        }
                        .contextMenu {
                            unsubscribeButton(subscription)
                        }
                }
            } header: {
                Text("新着の自動ダウンロード")
            } footer: {
                Text(seriesSubscriptionsFooter)
            }
        }
    }

    private var seriesSubscriptionsFooter: String {
        var parts = ["\(seriesSubscriptions.subscriptions.count)シリーズ"]
        if case let .completed(summary) = seriesSubscriptions.refreshState {
            parts.append(summary.message)
        }
        parts.append(
            "公開時刻を確認できる、購読開始後の新着だけを自動保存します。"
                + "公開時刻が不明な話は保存しません。"
                + "購読解除しても、保存済み・ダウンロード中の番組は残ります。"
        )
        return parts.joined(separator: "\n")
    }

    private func unsubscribeButton(_ subscription: SeriesSubscription) -> some View {
        Button(role: .destructive) {
            pendingUnsubscribe = subscription
        } label: {
            Label("購読解除", systemImage: "bell.slash")
        }
    }

    private func seriesSubscriptionRow(_ subscription: SeriesSubscription) -> some View {
        let detail = seriesSubscriptionDetail(subscription)
        let waiting: Text? = subscription.deferredCount > 0
            ? Text("待ち \(subscription.deferredCount)")
            : nil
        return VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            Text(subscription.seriesTitle)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .badge(waiting)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(subscription.seriesTitle)。\(detail)")
        .accessibilityHint("左にスワイプすると購読を解除できます。保存済みの番組は残ります")
    }

    private func seriesSubscriptionDetail(_ subscription: SeriesSubscription) -> String {
        var parts: [String] = []
        if let checkedAt = subscription.lastCheckedAt {
            parts.append("最終確認 \(Self.subscriptionDateFormatter.string(from: checkedAt))")
        } else {
            parts.append("現在の配信話をまだ確認できていません")
        }
        if subscription.deferredCount > 0 {
            parts.append("Wi-Fi待ち・再試行待ち \(subscription.deferredCount)件")
        }
        if case let .failed(message) = seriesSubscriptions.activity(for: subscription.seriesID) {
            parts.append("更新失敗: \(message)")
        } else if seriesSubscriptions.activity(for: subscription.seriesID)?.isBusy == true {
            parts.append("確認中")
        }
        return parts.joined(separator: "・")
    }

    @ViewBuilder
    private var downloadingSection: some View {
        if !inFlight.isEmpty {
            Section {
                ForEach(inFlight) { record in
                    row(for: record.program, state: record.state)
                        .tag(LibraryRowID.transfer(record.id))
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            transferActions(for: record.program, state: record.state)
                        }
                        .contextMenu {
                            downloadActions(for: record.program, state: record.state)
                        }
                }
            } header: {
                Text(Vocabulary.Download.running)
            } footer: {
                Text("\(inFlight.count)件")
            }
        }
    }

    @ViewBuilder
    private var savedSection: some View {
        if !saved.isEmpty {
            Section {
                ForEach(saved) { record in
                    row(for: record.program, state: record.state)
                        .tag(LibraryRowID.saved(record.id))
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            deleteSavedButton(record.program)
                        }
                        .contextMenu {
                            downloadActions(for: record.program, state: record.state)
                        }
                }
            } header: {
                Text(Vocabulary.Library.downloads)
            } footer: {
                Text("\(saved.count)件・\(DownloadStorageBar.formatted(downloadCenter.storage.usedBytes))")
            }
        }
    }

    @ViewBuilder
    private var favoritesSection: some View {
        if !libraryStore.favoritePrograms.isEmpty {
            Section {
                ForEach(libraryStore.favoritePrograms) { program in
                    let state = downloadCenter.state(for: program.id)
                    row(for: program, state: state)
                        .tag(LibraryRowID.favorite(program.id))
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            removeFavoriteButton(program)
                        }
                        .contextMenu {
                            downloadActions(for: program, state: state)
                            Divider()
                            removeFavoriteButton(program)
                        }
                }

                Button(role: .destructive, action: requestClearFavorites) {
                    Label("すべて外す", systemImage: "heart.slash")
                }
            } header: {
                Text(Vocabulary.Library.favorites)
            } footer: {
                Text("\(libraryStore.favoritePrograms.count)件")
            }
        }
    }

    @ViewBuilder
    private var recentsSection: some View {
        if !libraryStore.recentPrograms.isEmpty {
            Section {
                ForEach(libraryStore.recentPrograms) { program in
                    let state = downloadCenter.state(for: program.id)
                    row(for: program, state: state)
                        .tag(LibraryRowID.recent(program.id))
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            removeRecentButton(program)
                        }
                        .contextMenu {
                            downloadActions(for: program, state: state)
                            Divider()
                            removeRecentButton(program)
                        }
                }

                Button(role: .destructive, action: requestClearRecents) {
                    Label("すべて消す", systemImage: "clear")
                }
            } header: {
                Text(Vocabulary.Library.history)
            } footer: {
                Text("\(libraryStore.recentPrograms.count)件")
            }
        }
    }

    // MARK: - Rows

    private func row(for program: TVerProgram, state: DownloadState) -> some View {
        NavigationLink(value: program) {
            MediaRow(
                title: title(for: program),
                subtitle: program.title,
                detail: detail(for: program, state: state),
                thumbnailURL: program.thumbnailURL,
                badges: badges(for: program, state: state),
                progress: state.progress
            ) {
                DownloadButton(program: program)
            }
        }
    }

    // MARK: - Row actions

    /// 行の中の `DownloadButton` は `NavigationLink` の入れ子ボタンになるので、
    /// 同じ操作を必ずスワイプと長押しからも届くようにしておく。
    @ViewBuilder
    private func downloadActions(for program: TVerProgram, state: DownloadState) -> some View {
        switch state {
        case .notDownloaded:
            Button {
                downloadCenter.start(program)
            } label: {
                Label(Vocabulary.Download.action, systemImage: "arrow.down.circle")
            }
        case .queued:
            cancelButton(program)
        case .downloading:
            Button {
                downloadCenter.pause(program.id)
            } label: {
                Label("一時停止", systemImage: "pause.circle")
            }
            cancelButton(program)
        case .paused:
            resumeButton(program)
            cancelButton(program)
        case .failed:
            Button {
                downloadCenter.retry(program.id)
            } label: {
                Label("もう一度\(Vocabulary.Download.action)", systemImage: "arrow.clockwise.circle")
            }
            cancelButton(program)
        case .downloaded:
            deleteSavedButton(program)
        }
    }

    @ViewBuilder
    private func transferActions(for program: TVerProgram, state: DownloadState) -> some View {
        cancelButton(program)
        if case .downloading = state {
            Button {
                downloadCenter.pause(program.id)
            } label: {
                Label("一時停止", systemImage: "pause")
            }
        }
        if case .paused = state {
            resumeButton(program)
        }
    }

    private func cancelButton(_ program: TVerProgram) -> some View {
        Button(role: .destructive) {
            requestCancel(program)
        } label: {
            Label(Vocabulary.Download.cancel, systemImage: "xmark")
        }
    }

    private func resumeButton(_ program: TVerProgram) -> some View {
        Button {
            requestResume(program)
        } label: {
            Label(
                resumeLabel(for: program.id),
                systemImage: downloadCenter.isInterrupted(program.id)
                    ? "arrow.clockwise"
                    : "play"
            )
        }
    }

    private func deleteSavedButton(_ program: TVerProgram) -> some View {
        Button(role: .destructive) {
            requestDelete(program)
        } label: {
            Label(Vocabulary.Download.remove, systemImage: "trash")
        }
    }

    private func removeFavoriteButton(_ program: TVerProgram) -> some View {
        Button(role: .destructive) {
            requestRemoveFavorite(program)
        } label: {
            Label("\(Vocabulary.Library.favorites)から外す", systemImage: "heart.slash")
        }
    }

    private func removeRecentButton(_ program: TVerProgram) -> some View {
        Button(role: .destructive) {
            requestRemoveRecent(program)
        } label: {
            Label("\(Vocabulary.Library.history)から消す", systemImage: "clear")
        }
    }

    // MARK: - Destructive requests

    private func requestCancel(_ program: TVerProgram) {
        pendingAction = PendingDestructiveAction(
            confirmation: DownloadConfirmation(
                target: .runningDownload,
                subject: title(for: program)
            ),
            perform: { downloadCenter.cancel(program.id) }
        )
    }

    private func requestDelete(_ program: TVerProgram) {
        pendingAction = PendingDestructiveAction(
            confirmation: DownloadConfirmation(
                target: .savedDownload,
                subject: title(for: program)
            ),
            perform: { downloadCenter.delete(program.id) }
        )
    }

    /// 続きから戻せる転送はそのまま再開し、戻せないものだけ確認してやり直す。
    private func requestResume(_ program: TVerProgram) {
        guard downloadCenter.isInterrupted(program.id) else {
            downloadCenter.resume(program.id)
            return
        }
        pendingAction = PendingDestructiveAction(
            confirmation: DownloadConfirmation(
                target: .restartDownload,
                subject: title(for: program)
            ),
            perform: { downloadCenter.restart(program) }
        )
    }

    private func requestRemoveFavorite(_ program: TVerProgram) {
        pendingAction = PendingDestructiveAction(
            confirmation: DownloadConfirmation(target: .favorite, subject: title(for: program)),
            perform: { libraryStore.removeFavorite(program) }
        )
    }

    private func requestRemoveRecent(_ program: TVerProgram) {
        pendingAction = PendingDestructiveAction(
            confirmation: DownloadConfirmation(target: .recent, subject: title(for: program)),
            perform: { libraryStore.removeRecentProgram(program) }
        )
    }

    private func requestClearFavorites() {
        pendingAction = PendingDestructiveAction(
            confirmation: DownloadConfirmation(
                target: .allFavorites,
                subject: "\(libraryStore.favoritePrograms.count)件"
            ),
            perform: { libraryStore.clearFavorites() }
        )
    }

    private func requestClearRecents() {
        pendingAction = PendingDestructiveAction(
            confirmation: DownloadConfirmation(
                target: .allRecents,
                subject: "\(libraryStore.recentPrograms.count)件"
            ),
            perform: { libraryStore.clearRecentPrograms() }
        )
    }

    private func requestSelectionRemoval() {
        let rows = selection
        guard !rows.isEmpty else { return }
        pendingAction = PendingDestructiveAction(
            confirmation: DownloadConfirmation(target: .selection, subject: "\(rows.count)件"),
            perform: { remove(rows) }
        )
    }

    private func remove(_ rows: Set<LibraryRowID>) {
        for row in rows {
            switch row {
            case let .subscription(seriesID):
                seriesSubscriptions.unsubscribe(seriesID: seriesID)
            case let .transfer(programID):
                downloadCenter.cancel(programID)
            case let .saved(programID):
                downloadCenter.delete(programID)
            case let .favorite(programID):
                if let program = libraryStore.favoritePrograms.first(where: { $0.id == programID }) {
                    libraryStore.removeFavorite(program)
                }
            case let .recent(programID):
                if let program = libraryStore.recentPrograms.first(where: { $0.id == programID }) {
                    libraryStore.removeRecentProgram(program)
                }
            }
        }
        selection.removeAll()
    }

    // MARK: - Text

    private func title(for program: TVerProgram) -> String {
        program.seriesTitle.isEmpty ? program.title : program.seriesTitle
    }

    private func resumeLabel(for programID: String) -> String {
        downloadCenter.isInterrupted(programID) ? "最初からやり直す" : Vocabulary.Download.resume
    }

    private func badges(for program: TVerProgram, state: DownloadState) -> [MediaBadge] {
        var badges: [MediaBadge] = []
        switch state {
        case .notDownloaded:
            break
        case .queued:
            badges.append(MediaBadge(.downloading, text: Vocabulary.Download.queued))
        case .downloading:
            badges.append(MediaBadge(.downloading, text: Vocabulary.Download.running))
        case .paused:
            badges.append(MediaBadge(.downloading, text: Vocabulary.Download.paused))
        case .failed:
            badges.append(MediaBadge(.expiringSoon, text: "\(Vocabulary.Download.action)に失敗"))
        case .downloaded:
            badges.append(MediaBadge(.downloaded, text: Vocabulary.Library.downloads))
        }
        if let expiry = expiryBadge(for: program) {
            badges.append(expiry)
        }
        return badges
    }

    /// 期限は絶対時刻だけで判定する。表示用の文字列を読み直さない。
    private func expiryBadge(for program: TVerProgram) -> MediaBadge? {
        guard let deadline = program.availableUntilAt else { return nil }
        let remaining = deadline.timeIntervalSinceNow
        if remaining <= 0 { return MediaBadge(.expiringSoon, text: "配信終了") }
        if remaining <= 3 * 24 * 60 * 60 { return MediaBadge(.expiringSoon, text: "まもなく終了") }
        return nil
    }

    private func detail(for program: TVerProgram, state: DownloadState) -> String? {
        switch state {
        case .notDownloaded:
            return availability(for: program) ?? program.broadcastLabel
        case .queued:
            return Vocabulary.Download.queued
        case let .downloading(progress):
            return "\(Vocabulary.Download.running) \(percent(progress))"
        case let .paused(progress):
            guard downloadCenter.isInterrupted(program.id) else {
                return "\(Vocabulary.Download.paused) \(percent(progress))"
            }
            return "\(Vocabulary.Download.paused) \(percent(progress))・続きからは再開できません"
        case let .failed(message):
            return message
        case let .downloaded(bytes):
            return "\(Vocabulary.Library.downloads) \(DownloadStorageBar.formatted(bytes))"
        }
    }

    private func availability(for program: TVerProgram) -> String? {
        if let deadline = program.availableUntilAt {
            if deadline.timeIntervalSinceNow <= 0 { return "配信終了" }
            return "配信期限 \(Self.deadlineFormatter.string(from: deadline))"
        }
        if let text = program.availableUntil, !text.isEmpty { return "配信期限 \(text)" }
        return nil
    }

    private func percent(_ progress: Double) -> String {
        "\(Int((DownloadCenter.clamp(progress) * 100).rounded()))%"
    }

    private static let subscriptionDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.setLocalizedDateFormatFromTemplate("MdHm")
        return formatter
    }()

    private static let deadlineFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.setLocalizedDateFormatFromTemplate("Mdjm")
        return formatter
    }()
}

/// 端末に残る設定を集めた `Form` の画面。
///
/// 永続する設定をツールバーの `Menu` に置くと、その場の表示切替と区別が付かない。
/// iOS 標準アプリと同じく、切り替えたら残るものは設定画面に集める。
@MainActor
private struct LibraryDownloadSettingsView: View {
    @ObservedObject var downloadCenter: DownloadCenter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(
                        "Wi-Fiのときだけ\(Vocabulary.Download.action)",
                        isOn: $downloadCenter.wifiOnly
                    )
                    Toggle("視聴後に自動削除", isOn: $downloadCenter.deleteAfterWatching)
                } header: {
                    Text(Vocabulary.Download.action)
                } footer: {
                    Text(
                        "Wi-Fiのときだけにすると、モバイル通信では\(Vocabulary.Download.action)を始めません。"
                            + "視聴後に自動削除にすると、最後まで見た番組の動画ファイルを端末から消します。"
                    )
                }

                Section {
                    DownloadStorageBar(usage: downloadCenter.storage)
                    Button("空き容量を再計算") { downloadCenter.refreshStorage() }
                } header: {
                    Text("端末の容量")
                } footer: {
                    Text("「その他」はこのアプリ以外が使っている分です。")
                }
            }
            .navigationTitle("\(Vocabulary.Download.action)の設定")
            .toolbar {
                ToolbarItem(placement: ToolbarCompat.trailing) {
                    Button("完了") { dismiss() }
                }
            }
        }
    }
}
