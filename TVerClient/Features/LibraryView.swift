import SwiftUI

/// Download-first library. The capacity bar sits above four grouped lists:
/// transfers in flight, saved episodes, the kept programmes and the history.
///
/// 一覧の上には鮮度とお知らせを必ず置く。保存済みが消えたことも、転送が中断した
/// ことも、ここで言葉にしなければ利用者は気づけないまま番組を失う。
@MainActor
struct LibraryView: View {
    @ObservedObject var libraryStore: ProgramLibraryStore
    @ObservedObject var playbackController: PlaybackController
    @EnvironmentObject private var downloadCenter: DownloadCenter

    @State private var selectedProgram: TVerProgram?
    @State private var pendingAction: PendingDestructiveAction?
    @State private var isShowingDiagnostics = false

    /// 取り返しのつかない操作は、経路にかかわらずこの入れ物を通して確認する。
    private struct PendingDestructiveAction: Identifiable {
        let id = UUID()
        let confirmation: DownloadConfirmation
        let perform: () -> Void
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
            && libraryStore.favoritePrograms.isEmpty
            && libraryStore.recentPrograms.isEmpty
    }

    private var hasNotices: Bool {
        !downloadCenter.notices.isEmpty
            || downloadCenter.lastRejection != nil
            || libraryStore.didRecoverFromCorruptedStorage
            || libraryStore.lastPersistenceFailure != nil
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if downloadCenter.freshness.isDegraded {
                        FreshnessBanner(
                            freshness: downloadCenter.freshness,
                            retry: { downloadCenter.refreshStorage() }
                        )
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                    }
                    DownloadStorageBar(usage: downloadCenter.storage)
                        .listRowSeparator(.hidden)
                }

                if hasNotices {
                    Section { noticeRows }
                }

                if isEmpty {
                    Section {
                        ContentStatusView(.empty(
                            title: "\(Vocabulary.Library.downloads)の番組はありません",
                            message: "番組の右にある\(Vocabulary.Download.action)ボタンを押すと、通信のない場所でも見られます。",
                            systemImage: "arrow.down.circle"
                        ))
                        .listRowSeparator(.hidden)
                    }
                } else {
                    downloadingSection
                    savedSection
                    favoritesSection
                    recentsSection
                }
            }
            .listStyle(.plain)
            .navigationTitle("ライブラリ")
            .toolbar { settingsToolbar }
            .refreshable { downloadCenter.refreshStorage() }
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
        }
        .sheet(item: $selectedProgram) { program in
            PlaybackView(
                program: program,
                playbackController: playbackController,
                libraryStore: libraryStore
            )
        }
        .sheet(isPresented: $isShowingDiagnostics) {
            DiagnosticsView(logStore: DiagnosticLogStore.shared)
        }
        .onAppear { downloadCenter.refreshStorage() }
    }

    // MARK: - Notices

    @ViewBuilder
    private var noticeRows: some View {
        ForEach(downloadCenter.notices) { notice in
            noticeCard(
                systemImage: notice.kind.systemImage,
                tint: notice.kind == .warning ? DS.Palette.warning : DS.Palette.catchUp,
                message: notice.message,
                recovery: notice.recovery,
                actionLabel: notice.action.label,
                action: handler(for: notice.action),
                dismiss: { downloadCenter.dismissNotice(notice.id) }
            )
            .listRowSeparator(.hidden)
        }

        if let rejection = downloadCenter.lastRejection {
            noticeCard(
                systemImage: "exclamationmark.circle",
                tint: DS.Palette.warning,
                message: rejection.message,
                recovery: rejection.recovery,
                actionLabel: rejection.canRetryOnCellular
                    ? "今回だけモバイル通信で\(Vocabulary.Download.action)"
                    : nil,
                action: cellularOverride(for: rejection),
                dismiss: { downloadCenter.clearRejection() }
            )
            .listRowSeparator(.hidden)
        }

        if libraryStore.didRecoverFromCorruptedStorage {
            noticeCard(
                systemImage: "arrow.counterclockwise.circle",
                tint: DS.Palette.warning,
                message: "\(Vocabulary.Library.favorites)と\(Vocabulary.Library.history)の保存データが壊れていたため、読み直しました。",
                recovery: "一部が消えている場合があります。足りない番組はもう一度追加してください。",
                actionLabel: nil,
                action: nil,
                dismiss: { libraryStore.acknowledgeStorageRecovery() }
            )
            .listRowSeparator(.hidden)
        }

        if let failure = libraryStore.lastPersistenceFailure {
            noticeCard(
                systemImage: "exclamationmark.triangle.fill",
                tint: DS.Palette.warning,
                message: failure,
                recovery: "次に起動したとき\(Vocabulary.Library.favorites)が元に戻る場合があります。\(Vocabulary.Library.history)を減らすと保存しやすくなります。",
                actionLabel: clearRecentsAction() == nil
                    ? nil
                    : "\(Vocabulary.Library.history)をすべて消す",
                action: clearRecentsAction(),
                dismiss: { libraryStore.acknowledgePersistenceFailure() }
            )
            .listRowSeparator(.hidden)
        }
    }

    private func noticeCard(
        systemImage: String,
        tint: Color,
        message: String,
        recovery: String?,
        actionLabel: String?,
        action: (() -> Void)?,
        dismiss: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: DS.Spacing.s) {
            Image(systemName: systemImage)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text(message)
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                if let recovery = recovery {
                    Text(recovery)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let actionLabel = actionLabel, let action = action {
                    Button(actionLabel, action: action)
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(DS.Palette.catchUp)
                        .frame(
                            minWidth: DS.Size.minimumTapTarget,
                            minHeight: DS.Size.minimumTapTarget,
                            alignment: .leading
                        )
                        .accessibilityAddTraits(.isButton)
                }
            }
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption)
                    .frame(
                        width: DS.Size.minimumTapTarget,
                        height: DS.Size.minimumTapTarget
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("このお知らせを閉じる")
        }
        .padding(.vertical, DS.Spacing.xxs)
        .accessibilityElement(children: .contain)
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
    private var downloadingSection: some View {
        if !inFlight.isEmpty {
            Section {
                ForEach(inFlight) { record in
                    row(for: record.program, state: record.state)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                requestCancel(record)
                            } label: {
                                Label(Vocabulary.Download.cancel, systemImage: "xmark")
                            }
                            if case .downloading = record.state {
                                Button {
                                    downloadCenter.pause(record.id)
                                } label: {
                                    Label("一時停止", systemImage: "pause")
                                }
                            }
                            if case .paused = record.state {
                                Button {
                                    requestResume(record)
                                } label: {
                                    Label(
                                        resumeLabel(for: record.id),
                                        systemImage: downloadCenter.isInterrupted(record.id)
                                            ? "arrow.clockwise"
                                            : "play"
                                    )
                                }
                            }
                        }
                }
            } header: {
                SectionHeader(Vocabulary.Download.running, subtitle: "\(inFlight.count)件")
            }
        }
    }

    @ViewBuilder
    private var savedSection: some View {
        if !saved.isEmpty {
            Section {
                ForEach(saved) { record in
                    row(for: record.program, state: record.state)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                requestDelete(record)
                            } label: {
                                Label(Vocabulary.Download.remove, systemImage: "trash")
                            }
                        }
                }
            } header: {
                SectionHeader(
                    Vocabulary.Library.downloads,
                    subtitle: DownloadStorageBar.formatted(downloadCenter.storage.usedBytes)
                )
            }
        }
    }

    @ViewBuilder
    private var favoritesSection: some View {
        if !libraryStore.favoritePrograms.isEmpty {
            Section {
                ForEach(libraryStore.favoritePrograms) { program in
                    row(for: program, state: downloadCenter.state(for: program.id))
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                requestRemoveFavorite(program)
                            } label: {
                                Label(
                                    "\(Vocabulary.Library.favorites)から外す",
                                    systemImage: "heart.slash"
                                )
                            }
                        }
                }
            } header: {
                SectionHeader(
                    Vocabulary.Library.favorites,
                    subtitle: "\(libraryStore.favoritePrograms.count)件"
                ) {
                    bulkButton("すべて外す", action: requestClearFavorites)
                }
            }
        }
    }

    @ViewBuilder
    private var recentsSection: some View {
        if !libraryStore.recentPrograms.isEmpty {
            Section {
                ForEach(libraryStore.recentPrograms) { program in
                    row(for: program, state: downloadCenter.state(for: program.id))
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                requestRemoveRecent(program)
                            } label: {
                                Label(
                                    "\(Vocabulary.Library.history)から消す",
                                    systemImage: "clear"
                                )
                            }
                        }
                }
            } header: {
                SectionHeader(
                    Vocabulary.Library.history,
                    subtitle: "\(libraryStore.recentPrograms.count)件"
                ) {
                    bulkButton("すべて消す", action: requestClearRecents)
                }
            }
        }
    }

    private func bulkButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.caption2)
            .buttonStyle(.plain)
            .foregroundStyle(DS.Palette.catchUp)
            .frame(
                minWidth: DS.Size.minimumTapTarget,
                minHeight: DS.Size.minimumTapTarget,
                alignment: .trailing
            )
            .accessibilityAddTraits(.isButton)
    }

    @ToolbarContentBuilder
    private var settingsToolbar: some ToolbarContent {
        ToolbarItem(placement: ToolbarCompat.trailing) {
            Menu {
                Toggle(
                    "Wi-Fiのときだけ\(Vocabulary.Download.action)",
                    isOn: $downloadCenter.wifiOnly
                )
                Toggle("視聴後に自動削除", isOn: $downloadCenter.deleteAfterWatching)
                Divider()
                Button {
                    downloadCenter.refreshStorage()
                } label: {
                    Label("空き容量を再計算", systemImage: "arrow.clockwise")
                }
                Button {
                    isShowingDiagnostics = true
                } label: {
                    Label("通信診断とログ", systemImage: "stethoscope")
                }
            } label: {
                Image(systemName: "gearshape")
                    .frame(
                        width: DS.Size.minimumTapTarget,
                        height: DS.Size.minimumTapTarget
                    )
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("\(Vocabulary.Download.action)の設定")
        }
    }

    // MARK: - Rows

    private func row(for program: TVerProgram, state: DownloadState) -> some View {
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
        .contentShape(Rectangle())
        .onTapGesture { open(program) }
        .accessibilityElement(children: .contain)
        .accessibilityValue(Text(detail(for: program, state: state) ?? ""))
        .accessibilityAction(named: Text("再生")) { open(program) }
    }

    // MARK: - Destructive requests

    private func requestCancel(_ record: DownloadRecord) {
        pendingAction = PendingDestructiveAction(
            confirmation: DownloadConfirmation(
                target: .runningDownload,
                subject: title(for: record.program)
            ),
            perform: { downloadCenter.cancel(record.id) }
        )
    }

    private func requestDelete(_ record: DownloadRecord) {
        pendingAction = PendingDestructiveAction(
            confirmation: DownloadConfirmation(
                target: .savedDownload,
                subject: title(for: record.program)
            ),
            perform: { downloadCenter.delete(record.id) }
        )
    }

    /// 続きから戻せる転送はそのまま再開し、戻せないものだけ確認してやり直す。
    private func requestResume(_ record: DownloadRecord) {
        guard downloadCenter.isInterrupted(record.id) else {
            downloadCenter.resume(record.id)
            return
        }
        pendingAction = PendingDestructiveAction(
            confirmation: DownloadConfirmation(
                target: .restartDownload,
                subject: title(for: record.program)
            ),
            perform: { downloadCenter.restart(record.program) }
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

    private func open(_ program: TVerProgram) {
        DiagnosticLogStore.shared.record(
            .info,
            category: "library",
            message: "Library row opened for playback"
        )
        selectedProgram = program
    }

    private static let deadlineFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.setLocalizedDateFormatFromTemplate("Mdjm")
        return formatter
    }()
}
