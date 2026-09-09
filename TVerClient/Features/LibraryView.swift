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
    @State private var path: [TVerProgram] = []
    @State private var selection: Set<LibraryRowID> = []
    @State private var category: Category = .saved
    @State private var editMode: EditMode = .inactive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// 分類は空でも選べる。保存済みが0件でも、履歴や停止した転送を見失わない。
    enum Category: String, CaseIterable, Identifiable {
        case saved, transfers, favorites, recents, subscriptions

        var id: String { rawValue }

        var title: String {
            switch self {
            case .saved: return Vocabulary.Library.downloads
            case .transfers: return "進行中・停止・失敗"
            case .favorites: return Vocabulary.Library.favorites
            case .recents: return Vocabulary.Library.history
            case .subscriptions: return "新着の自動ダウンロード"
            }
        }

        var systemImage: String {
            switch self {
            case .saved: return "arrow.down.circle.fill"
            case .transfers: return "arrow.triangle.2.circlepath"
            case .favorites: return "heart"
            case .recents: return "clock"
            case .subscriptions: return "bell"
            }
        }

        var emptyTitle: String {
            switch self {
            case .saved: return "ダウンロード済みの番組はありません"
            case .transfers: return "進行中・停止中のダウンロードはありません"
            case .favorites: return "マイリストは空です"
            case .recents: return "視聴履歴はありません"
            case .subscriptions: return "自動ダウンロードは登録されていません"
            }
        }

        var emptyMessage: String {
            switch self {
            case .saved:
                return "「見逃し」から番組を開き、ダウンロードを選ぶと、完了した番組がここに表示されます。進行状況は上の分類で確認できます。"
            case .transfers:
                return "ダウンロードの順番待ち・進行状況・一時停止・失敗をここで確認できます。完了した番組は「ダウンロード済み」に移ります。"
            case .favorites:
                return "番組を開き、ハートのボタンで追加できます。マイリストへの追加だけでは動画はダウンロードされません。"
            case .recents:
                return "見た番組がここに表示されます。履歴を消しても、ダウンロード済みの動画やマイリストは残ります。"
            case .subscriptions:
                return "シリーズのある番組を開き、「新着を自動ダウンロード」を選ぶと登録できます。今後の新着だけが対象です。"
            }
        }

        func includesDownload(_ state: DownloadState) -> Bool {
            switch (self, state) {
            case (.saved, .downloaded): return true
            case (.transfers, .queued), (.transfers, .downloading),
                 (.transfers, .paused), (.transfers, .failed): return true
            default: return false
            }
        }

        var selectionKind: DownloadConfirmation.SelectionKind {
            switch self {
            case .saved: return .savedDownloads
            case .transfers: return .transfers
            case .favorites: return .favorites
            case .recents: return .recents
            case .subscriptions: return .subscriptions
            }
        }
    }

    /// 取り返しのつかない操作は、経路にかかわらずこの入れ物を通して確認する。
    private struct PendingDestructiveAction: Identifiable {
        let id = UUID()
        let confirmation: DownloadConfirmation
        let perform: () -> Void
    }

    /// 編集モードの選択キー。同じ番組が保存済みとマイリストの両方に並ぶので、
    /// 番組IDだけを鍵にすると片方を選んだだけで両方が選ばれてしまう。
    enum LibraryRowID: Hashable {
        case subscription(String)
        case transfer(String)
        case saved(String)
        case favorite(String)
        case recent(String)
    }

    private func rowIDs(in category: Category) -> Set<LibraryRowID> {
        switch category {
        case .saved: return Set(saved.map { .saved($0.id) })
        case .transfers: return Set(inFlight.map { .transfer($0.id) })
        case .favorites: return Set(libraryStore.favoritePrograms.map { .favorite($0.id) })
        case .recents: return Set(libraryStore.recentPrograms.map { .recent($0.id) })
        case .subscriptions:
            return Set(seriesSubscriptions.subscriptions.map { .subscription($0.seriesID) })
        }
    }

    private var visibleRowIDs: Set<LibraryRowID> { rowIDs(in: category) }

    /// 非表示・削除済み・完了して別分類へ移った行を破壊的操作の対象にしない。
    static func removableSelection(
        _ selection: Set<LibraryRowID>,
        visibleRows: Set<LibraryRowID>,
        isEditing: Bool
    ) -> Set<LibraryRowID> {
        isEditing ? selection.intersection(visibleRows) : []
    }

    private var selectedRows: Set<LibraryRowID> {
        Self.removableSelection(selection, visibleRows: visibleRowIDs, isEditing: editMode.isEditing)
    }

    private func finishSelection() {
        selection.removeAll()
        editMode = .inactive
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
        downloadCenter.records.filter { Category.transfers.includesDownload($0.state) }
    }

    private var saved: [DownloadRecord] {
        downloadCenter.records.filter { Category.saved.includesDownload($0.state) }
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
        NavigationStack(path: $path) {
            ScrollViewReader { proxy in
                libraryList
                    .onReceive(tabReselection.events) { tab in
                        // 表示中のタブをもう一度選んだら先頭へ戻る。iOS 標準の動き。
                        guard tab == .library else { return }
                        withAnimation(reduceMotion ? nil : .default) {
                            proxy.scrollTo(StandardScrollAnchor.top, anchor: .top)
                        }
                    }
                    .onChange(of: category) { _ in
                        proxy.scrollTo(StandardScrollAnchor.top, anchor: .top)
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
        .environment(\.editMode, $editMode)
        .onChange(of: category) { _ in finishSelection() }
        .onChange(of: path) { _ in finishSelection() }
        .onChange(of: visibleRowIDs) { rows in
            selection = Self.removableSelection(selection, visibleRows: rows, isEditing: editMode.isEditing)
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .settings:
                LibraryDownloadSettingsView(downloadCenter: downloadCenter)
            case .diagnostics:
                DiagnosticsView(logStore: DiagnosticLogStore.shared)
            }
        }
        .onPlayerPresentationRequest(playbackController.presentationRequestToken) {
            // ミニプレイヤーからの戻り。再生中の番組を push し直す。
            guard let program = playbackController.currentProgram else { return }
            if path.last != program {
                path = [program]
            }
        }
        .onAppear { downloadCenter.refreshStorage() }
    }

    private var libraryList: some View {
        List(selection: editMode.isEditing ? $selection : nil) {
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
            if let failure = cellularOverride(for: rejection) {
                Button(failure.cellularRetryLabel) {
                    downloadCenter.clearRejection()
                    Task { @MainActor in
                        await Task.yield()
                        // このalertはLibraryの操作を所有する。再拒否もglobal側に残す。
                        _ = failure.performCellularRetry(on: downloadCenter)
                    }
                }
            }
            Button("閉じる", role: .cancel) { downloadCenter.clearRejection() }
        } message: { rejection in
            Text(rejectionMessage(rejection))
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                freshnessBanner
                categoryPicker
            }
        }
    }

    private func categoryEntryCount(_ value: Category) -> Int {
        value == .favorites ? libraryStore.favoriteProgramIDs.count : rowIDs(in: value).count
    }

    /// 常設の分類切り替え。狭い画面でも5つのラベルを押し込んで縮小しない。
    private var categoryPicker: some View {
        Menu {
            Picker("表示する分類", selection: $category) {
                ForEach(Category.allCases) { item in
                    Label("\(item.title)（\(categoryEntryCount(item))）", systemImage: item.systemImage)
                        .tag(item)
                }
            }
        } label: {
            LibraryCategoryMenuLabel(title: category.title, count: categoryEntryCount(category))
        }
        .padding(.horizontal, DS.Spacing.m)
        .background(.bar)
        .accessibilityLabel("分類: \(category.title)、\(categoryEntryCount(category))件")
        .accessibilityHint("ダウンロード済み、進行状況、マイリスト、履歴、自動ダウンロードを切り替えます")
        .accessibilityIdentifier("library.category")
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
        if visibleRowIDs.isEmpty {
            Section {
                ContentStatusView(.empty(
                    title: category == .favorites && !libraryStore.favoriteProgramIDs.isEmpty
                        ? "マイリストの番組情報がありません" : category.emptyTitle,
                    message: category == .favorites && !libraryStore.favoriteProgramIDs.isEmpty
                        ? "\(libraryStore.favoriteProgramIDs.count)件の登録は残っていますが、保存された番組情報が不足しているため一覧を表示できません。番組は「見逃し」や検索から確認できます。"
                        : category.emptyMessage,
                    systemImage: category.systemImage
                ))
                .accessibilityIdentifier("library.empty.\(category.rawValue)")
            }
        } else {
            switch category {
            case .saved: savedSection
            case .transfers: downloadingSection
            case .favorites: favoritesSection
            case .recents: recentsSection
            case .subscriptions: seriesSubscriptionsSection
            }
        }
    }

    private func playbackDestination(for program: TVerProgram) -> some View {
        // 視聴画面はこの NavigationStack にそのまま積む。入れ子にすると
        // バーが二段になるだけでなく、push 直後に落ちることがある。
        PlaybackView(
            program: program,
            playbackController: playbackController,
            libraryStore: libraryStore
        )
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
            if !visibleRowIDs.isEmpty || editMode.isEditing {
                Button(editMode.isEditing ? "完了" : "選択") {
                    if editMode.isEditing {
                        finishSelection()
                    } else {
                        selection.removeAll()
                        editMode = .active
                    }
                }
                .accessibilityIdentifier("library.selection-mode")
            }
        }
        ToolbarItem(placement: ToolbarCompat.trailing) {
            Menu {
                if editMode.isEditing {
                    Button(selectedRows == visibleRowIDs ? "選択を解除" : "この分類をすべて選択") {
                        selection = selectedRows == visibleRowIDs ? [] : visibleRowIDs
                    }
                    Divider()
                }
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
            if editMode.isEditing {
                Text("\(selectedRows.count)件選択")
                    .monospacedDigit()
                Spacer()
                Button(category.selectionKind.confirmLabel, role: .destructive) {
                    requestSelectionRemoval()
                }
                .disabled(selectedRows.isEmpty)
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
                        recovery: nil,
                        actionLabel: nil,
                        action: nil,
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

    /// ボタンが同期的に消費した拒否はここへ来ない。一覧操作などの未消費分だけを扱う。
    private var rejectionPresentation: Binding<Bool> {
        Binding(
            get: { downloadCenter.lastRejection != nil },
            set: { isPresented in
                if !isPresented { downloadCenter.clearRejection() }
            }
        )
    }

    private func rejectionMessage(_ rejection: DownloadCenter.Rejection) -> String {
        if let failure = cellularOverride(for: rejection) { return failure.message }
        return [rejection.message, rejection.recovery]
            .compactMap { $0 }
            .joined(separator: "\n")
    }

    private func handler(for action: DownloadNotice.Action) -> (() -> Void)? {
        switch action {
        case .none:
            return nil
        case .restart:
            return {
                guard let request = action.prepareRestart(on: downloadCenter) else { return }
                pendingAction = PendingDestructiveAction(
                    confirmation: request.confirmation,
                    perform: {
                        Task { @MainActor in
                            // Let the confirmation close before a possible refusal alert is presented.
                            await Task.yield()
                            request.perform(on: downloadCenter)
                        }
                    }
                )
            }
        case let .resumeOnCellular(programIDs, _):
            return { downloadCenter.resumeAllAllowingCellular(programIDs) }
        }
    }

    private func cellularOverride(for rejection: DownloadCenter.Rejection) -> DownloadButton.RequestFailure? {
        guard rejection.canRetryOnCellular, let program = rejection.program,
              program.id == rejection.programID,
              let request = DownloadButton.Request.recoveryRequest(
                for: downloadCenter.state(for: program.id), isInterrupted: downloadCenter.isInterrupted(program.id)
              ) else { return nil }
        return DownloadButton.RequestFailure(rejection: rejection, program: program, request: request)
    }

    private func clearRecentsAction() -> (() -> Void)? {
        guard !libraryStore.recentPrograms.isEmpty else { return nil }
        return { requestClearRecents() }
    }

    // MARK: - Sections

    /// The pinned picker already names this category; do not repeat it at accessibility sizes.
    @ViewBuilder
    private func sectionHeading(for section: Category) -> some View {
        let layout = LibraryPresentationLayout(dynamicTypeSize: dynamicTypeSize)
        if layout.showsSectionHeading(section, selected: category) {
            Text(section.title)
        }
    }

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
                sectionHeading(for: .subscriptions)
            } footer: {
                Text(seriesSubscriptionsFooter)
            }
        }
    }

    private var seriesSubscriptionsFooter: String {
        var parts = ["\(seriesSubscriptions.subscriptions.count)シリーズ"]
        if case let .completed(summary) = seriesSubscriptions.refreshState {
            parts.append("前回の新着確認結果: \(summary.message)")
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
                sectionHeading(for: .transfers)
            } footer: {
                Text("\(inFlight.count)件。完了すると「\(Vocabulary.Library.downloads)」に移ります。")
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
                sectionHeading(for: .saved)
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
            } header: {
                sectionHeading(for: .favorites)
            } footer: {
                Text(libraryStore.favoriteProgramIDs.count == libraryStore.favoritePrograms.count
                    ? "\(libraryStore.favoritePrograms.count)件"
                    : "\(libraryStore.favoriteProgramIDs.count)件登録・番組情報\(libraryStore.favoritePrograms.count)件")
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
            } header: {
                sectionHeading(for: .recents)
            } footer: {
                Text("\(libraryStore.recentPrograms.count)件")
            }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(for program: TVerProgram, state: DownloadState) -> some View {
        if editMode.isEditing {
            // 選択中は再生やダウンロードを起動しない。
            mediaRow(for: program, state: state)
        } else {
            LibraryRowContainer {
                NavigationLink(value: program) {
                    mediaRow(for: program, state: state)
                }
                .accessibilityHint("視聴画面を開きます。戻るとこの分類の一覧に戻ります")
            } accessory: {
                // NavigationLinkのラベル内に操作ボタンを入れない。
                DownloadButton(program: program)
            }
        }
    }

    private func mediaRow(for program: TVerProgram, state: DownloadState) -> some View {
        MediaRow(
            title: title(for: program),
            subtitle: program.title == title(for: program) ? nil : program.title,
            detail: detail(for: program, state: state),
            thumbnailURL: program.thumbnailURL,
            badges: badges(for: program, state: state),
            progress: state.progress
        )
    }

    // MARK: - Row actions

    /// 行の独立した操作ボタンに加え、スワイプと長押しからも同じ安全な操作へ届く。
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
                Label("最初から再試行", systemImage: "arrow.clockwise.circle")
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
        if case .failed = state {
            Button {
                downloadCenter.retry(program.id)
            } label: {
                Label("最初から再試行", systemImage: "arrow.clockwise")
            }
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
            perform: {
                guard downloadCenter.state(for: program.id).isFinished else { return }
                downloadCenter.delete(program.id)
            }
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
            perform: {
                // 確認中に別の経路で再開・完了した転送を捨てない。
                guard case .paused = downloadCenter.state(for: program.id),
                      downloadCenter.isInterrupted(program.id) else { return }
                downloadCenter.restart(program)
            }
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
        let rows = selectedRows
        guard !rows.isEmpty else { return }
        pendingAction = PendingDestructiveAction(
            confirmation: DownloadConfirmation(
                target: .selection,
                subject: "\(rows.count)件",
                selectionKind: category.selectionKind
            ),
            perform: { remove(rows) }
        )
    }

    private func remove(_ rows: Set<LibraryRowID>) {
        let currentRows = Self.removableSelection(
            rows, visibleRows: visibleRowIDs, isEditing: editMode.isEditing
        )
        for row in currentRows {
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
        finishSelection()
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
                return "\(Vocabulary.Download.paused) \(percent(progress))・再開できます"
            }
            return "中断 \(percent(progress))・最初からやり直してください"
        case let .failed(message):
            return "失敗: \(message)・再試行は最初からになります"
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
                    Text("「その他」にはOSや他のアプリ、このアプリの動画以外のデータが含まれます。")
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
