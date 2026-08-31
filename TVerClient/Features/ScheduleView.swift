import AVKit
import Foundation
import Combine
import SwiftUI

@MainActor
final class ScheduleViewModel: ObservableObject {
    @Published private(set) var days: [ProgramDay] = []
    @Published private(set) var isLoading = false
    @Published private(set) var failure: StatusFailure?
    /// いま見えている一覧をどれだけ信用してよいか。
    ///
    /// 一覧が出ている状態で更新に失敗しても、以前はスピナーが消えるだけで
    /// 何も起きなかった。利用者は古い一覧を最新だと信じてしまう。
    @Published private(set) var freshness: LoadFreshness

    private let service: any TVerCatalogServicing
    /// 鮮度まで返せる実装なら、そちらから受け取る。
    private let snapshotProvider: (any TVerScheduleSnapshotProviding)?
    private let usesPreviewFallback: Bool
    private let now: @Sendable () -> Date
    private var hasLoaded = false
    private var lastGoodAt: Date?

    init(
        service: any TVerCatalogServicing,
        usesPreviewFallback: Bool = true,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.service = service
        snapshotProvider = service as? any TVerScheduleSnapshotProviding
        self.usesPreviewFallback = usesPreviewFallback
        self.now = now
        freshness = .fresh(at: now())
    }

    var showsInitialLoading: Bool {
        isLoading && days.isEmpty
    }

    var hasPrograms: Bool {
        days.contains { !$0.programs.isEmpty }
    }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await load()
    }

    /// - Parameter forceRefresh: 引き下げ更新のように、利用者が明示的に
    ///   最新を求めた操作かどうか。短命キャッシュを黙って返さないために要る。
    func load(forceRefresh: Bool = false) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let snapshot = try await scheduleSnapshot(forceRefresh: forceRefresh)
            days = resolved(snapshot.days)
            freshness = snapshot.freshness
            if case let .fresh(at) = snapshot.freshness {
                lastGoodAt = at
            }
            failure = nil
            hasLoaded = true
        } catch {
            let statusFailure = StatusFailure(error)
            failure = statusFailure
            if hasPrograms {
                // 一覧が残っているときは、それが古いことを必ず画面に出す。
                freshness = .refreshFailed(
                    lastGoodAt: lastGoodAt,
                    message: statusFailure.summary,
                    recovery: statusFailure.recovery
                )
            }
            DiagnosticLogStore.shared.record(
                .error,
                category: "catalog",
                message: "Schedule loading failed",
                metadata: ["error": statusFailure.summary]
            )
        }
    }

    private func scheduleSnapshot(forceRefresh: Bool) async throws -> ScheduleSnapshot {
        if let snapshotProvider {
            return try await snapshotProvider.fetchScheduleSnapshot(forceRefresh: forceRefresh)
        }
        let loaded = try await service.fetchSchedule(forceRefresh: forceRefresh)
        return ScheduleSnapshot(days: loaded, freshness: .fresh(at: now()))
    }

    private func resolved(_ response: [ProgramDay]) -> [ProgramDay] {
        #if DEBUG
            return response.isEmpty && usesPreviewFallback ? PreviewFixture.schedule : response
        #else
            return response
        #endif
    }
}

/// Works out when a programme disappears from the catch-up catalogue.
///
/// 期限は API から絶対時刻で届く。年の無い表示用文字列に一度落としてから
/// 読み直すと、年末年始や閏年で年を取り違え、まだ見られる番組を「配信終了」
/// と表示してしまう。文字列の解釈は絶対時刻を持たない古いデータ専用。
enum ScheduleExpiry {
    /// Rows with this many days left or fewer get the countdown badge.
    static let expiringSoonThresholdDays = 1

    /// Deadlines are published in Japan time no matter where the device is,
    /// so the countdown is always computed against that calendar.
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "ja_JP")
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current
        return calendar
    }

    /// 番組の配信期限。絶対時刻があるときは必ずそちらを使う。
    static func deadline(
        for program: TVerProgram,
        now: Date,
        calendar: Calendar = ScheduleExpiry.calendar
    ) -> Date? {
        if let absolute = program.availableUntilAt { return absolute }
        // 旧データ互換。絶対時刻を持たないときだけ文字列の推定に戻る。
        return deadline(from: program.availableUntil, now: now, calendar: calendar)
    }

    /// 残り日数。絶対時刻があるときは推定を挟まないので誤判定しない。
    static func remainingDays(
        for program: TVerProgram,
        now: Date,
        calendar: Calendar = ScheduleExpiry.calendar
    ) -> Int? {
        guard let deadline = deadline(for: program, now: now, calendar: calendar) else { return nil }
        return remainingDays(until: deadline, now: now, calendar: calendar)
    }

    /// 画面に出す期限。放送日の慣習に合わせて 24〜28 時表記を使う。
    static func deadlineLabel(for program: TVerProgram, now: Date) -> String? {
        guard let deadline = deadline(for: program, now: now) else {
            let fallback = program.availableUntil?.trimmingCharacters(in: .whitespacesAndNewlines)
            return fallback?.isEmpty == false ? fallback : nil
        }
        return "\(broadcastDateLabel(for: deadline))\(BroadcastDay.timeLabel(for: deadline))まで"
    }

    static func deadline(
        from label: String?,
        now: Date,
        calendar: Calendar = ScheduleExpiry.calendar
    ) -> Date? {
        guard let label, !label.isEmpty, let parsed = monthAndDay(in: label) else { return nil }
        let time = hourAndMinute(in: label)
        let referenceYear = calendar.component(.year, from: now)
        // The label carries no year, so read it as the occurrence closest to
        // now. That keeps a late-December list pointing at next January.
        let candidates = [referenceYear - 1, referenceYear, referenceYear + 1]
            .compactMap { year -> Date? in
                var components = DateComponents()
                components.year = year
                components.month = parsed.month
                components.day = parsed.day
                components.hour = time?.hour ?? 23
                components.minute = time?.minute ?? 59
                return calendar.date(from: components)
            }
        return candidates.min { abs($0.timeIntervalSince(now)) < abs($1.timeIntervalSince(now)) }
    }

    static func remainingDays(
        from label: String?,
        now: Date,
        calendar: Calendar = ScheduleExpiry.calendar
    ) -> Int? {
        guard let deadline = deadline(from: label, now: now, calendar: calendar) else { return nil }
        return remainingDays(until: deadline, now: now, calendar: calendar)
    }

    /// Whole calendar days left, so "tonight" and "in twenty minutes" both
    /// read as the same urgency instead of rounding to zero at different times.
    static func remainingDays(
        until deadline: Date,
        now: Date,
        calendar: Calendar = ScheduleExpiry.calendar
    ) -> Int {
        let start = calendar.startOfDay(for: now)
        let end = calendar.startOfDay(for: deadline)
        return calendar.dateComponents([.day], from: start, to: end).day ?? 0
    }

    static func isExpiringSoon(_ remainingDays: Int) -> Bool {
        remainingDays <= expiringSoonThresholdDays
    }

    static func countdownText(for remainingDays: Int) -> String {
        if remainingDays < 0 { return "配信終了" }
        if remainingDays == 0 { return "本日まで" }
        return "残り\(remainingDays)日"
    }

    private static func broadcastDateLabel(for date: Date) -> String {
        let calendar = BroadcastDay.calendar
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale ?? Locale(identifier: "ja_JP")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "M月d日(E) "
        return formatter.string(from: BroadcastDay.day(containing: date, calendar: calendar))
    }

    private static func monthAndDay(in label: String) -> (month: Int, day: Int)? {
        guard let groups = firstMatch(pattern: "([0-9]{1,2})月([0-9]{1,2})日", in: label),
              groups.count == 2,
              (1 ... 12).contains(groups[0]),
              (1 ... 31).contains(groups[1])
        else { return nil }
        return (groups[0], groups[1])
    }

    private static func hourAndMinute(in label: String) -> (hour: Int, minute: Int)? {
        guard let groups = firstMatch(pattern: "([0-9]{1,2}):([0-9]{2})", in: label),
              groups.count == 2,
              (0 ... 23).contains(groups[0]),
              (0 ... 59).contains(groups[1])
        else { return nil }
        return (groups[0], groups[1])
    }

    private static func firstMatch(pattern: String, in value: String) -> [Int]? {
        let normalized = value.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? value
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(normalized.startIndex ..< normalized.endIndex, in: normalized)
        guard let match = regex.firstMatch(in: normalized, range: range) else { return nil }
        var groups: [Int] = []
        for index in 1 ..< match.numberOfRanges {
            guard let groupRange = Range(match.range(at: index), in: normalized),
                  let number = Int(normalized[groupRange])
            else { return nil }
            groups.append(number)
        }
        return groups
    }
}

@MainActor
struct ScheduleView: View {
    @StateObject private var viewModel: ScheduleViewModel
    @StateObject private var searchViewModel: ProgramSearchViewModel
    @ObservedObject private var playbackController: PlaybackController
    @ObservedObject private var libraryStore: ProgramLibraryStore
    @EnvironmentObject private var downloadCenter: DownloadCenter
    /// 表示中のタブをもう一度選んだ合図を受け取る共通のチャネル。
    @EnvironmentObject private var tabReselection: TabReselection
    /// 視聴画面は push で開く。同じタブの再選択でルートへ戻せるよう経路を持つ。
    @State private var path: [TVerProgram] = []
    /// スワイプと長押しから中止・削除するときに出す確認。
    @State private var pendingDownload: PendingDownloadAction?
    @State private var now = Date()

    /// まもなく終わる番組をリストの先頭に出す本数。多すぎると本編の一覧が
    /// 押し出されるので、拾い読みできる範囲で止める。
    private static let expiringSoonLimit = 5

    /// 行の中にダウンロードのボタンを置けない代わりに、スワイプと長押しから
    /// 同じ操作を出す。中止と削除はボタン経由と同じ確認を必ず通す。
    private struct PendingDownloadAction: Identifiable, Equatable {
        let program: TVerProgram
        let confirmation: DownloadConfirmation

        var id: String { "\(program.id):\(confirmation.id)" }
    }

    init(
        viewModel: ScheduleViewModel,
        playbackController: PlaybackController,
        libraryStore: ProgramLibraryStore
    ) {
        _viewModel = StateObject(wrappedValue: viewModel)
        _searchViewModel = StateObject(
            wrappedValue: ProgramSearchViewModel(index: .videoOnDemand([]))
        )
        self.playbackController = playbackController
        self.libraryStore = libraryStore
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("見逃し")
                .toolbar { toolbarContent }
                .navigationDestination(for: TVerProgram.self) { program in
                    playbackDestination(for: program)
                }
                // 常時表示をやめ、引き下げで現れる標準の検索欄に戻す。
                // 入力先は searchViewModel.query のまま変えない。
                .searchable(
                    text: $searchViewModel.query,
                    prompt: Text(ProgramSearchAccessibilityText.fieldLabel)
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .onPlayerPresentationRequest(playbackController.presentationRequestToken) {
            // ミニプレイヤーからの戻り。再生中の番組を push し直す。
            guard let program = playbackController.currentProgram else { return }
            if path.last != program {
                path = [program]
            }
        }
        .task {
            await viewModel.loadIfNeeded()
            refreshSearchIndex()
        }
        .onChange(of: viewModel.days) { _ in
            now = Date()
            refreshSearchIndex()
        }
        .onChange(of: libraryStore.favoriteProgramIDs) { _ in
            refreshSearchIndex()
        }
        .onChange(of: path) { newPath in
            // 行のタップは NavigationLink が受けるので、記録はここで取る。
            guard !newPath.isEmpty else { return }
            DiagnosticLogStore.shared.record(
                .info,
                category: "playback",
                message: "VOD playback selected"
            )
        }
        .confirmationDialog(
            Text(pendingDownload?.confirmation.title ?? ""),
            isPresented: Binding(
                get: { pendingDownload != nil },
                set: { isPresented in
                    if !isPresented { pendingDownload = nil }
                }
            ),
            titleVisibility: .visible,
            presenting: pendingDownload
        ) { pending in
            Button(
                pending.confirmation.confirmLabel,
                role: pending.confirmation.isDestructive ? ButtonRole.destructive : nil
            ) {
                performDownloadAction(pending)
                pendingDownload = nil
            }
            Button("やめる", role: .cancel) { pendingDownload = nil }
        } message: { pending in
            Text(pending.confirmation.message)
        }
    }

    /// 視聴画面はこのタブの NavigationStack にそのまま積む。以前は視聴画面が
    /// 自前の NavigationStack を持っていたため push 先で入れ子になり、検索欄を
    /// 持つこのタブでは再生に入ろうとした瞬間に落ちていた。
    private func playbackDestination(for program: TVerProgram) -> some View {
        PlaybackView(
            program: program,
            playbackController: playbackController,
            libraryStore: libraryStore
        )
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.showsInitialLoading {
            ContentStatusView(.loading("最新の配信情報を取得しています。"))
        } else if let failure = viewModel.failure, !viewModel.hasPrograms {
            ContentStatusView(
                .recoverableFailure(
                    title: failure.title,
                    message: failure.message,
                    recovery: failure.recovery
                ),
                retryTitle: "再読み込み",
                retry: { reload() }
            )
        } else if !viewModel.hasPrograms {
            ContentStatusView(
                .empty(
                    title: "見逃し配信がありません",
                    message: "時間をおいて、もう一度更新してください。",
                    systemImage: "tv.slash"
                ),
                retryTitle: "更新",
                retry: { reload() }
            )
        } else {
            scheduleList
        }
    }

    private var scheduleList: some View {
        ScrollViewReader { proxy in
            List {
                if isSearchPresentationActive {
                    searchSection
                        .id(StandardScrollAnchor.top)
                } else {
                    if !expiringSoonPrograms.isEmpty {
                        expiringSoonSection
                            .id(StandardScrollAnchor.top)
                    }
                    ForEach(populatedDays, id: \.date) { day in
                        Section {
                            ForEach(day.programs, id: \.id) { program in
                                programRow(program)
                            }
                        } header: {
                            sectionHeader(dayTitle(for: day.date), subtitle: "\(day.programs.count)本")
                        }
                        .id(dayAnchorID(for: day))
                    }
                }
            }
            .listStyle(.plain)
            .refreshable { await reloadAsync(forceRefresh: true) }
            // 常設帯は1枚にまとめてここに固定する。どちらも出ていないときは
            // 高さ 0 になり、区切り線も残らない。
            .safeAreaInset(edge: .top, spacing: 0) { topBands }
            .onReceive(tabReselection.events) { tab in
                guard tab == .catchUp else { return }
                // 標準アプリと同じ順序。まず視聴画面を畳み、次に先頭へ戻す。
                if !path.isEmpty {
                    path.removeAll()
                    return
                }
                withAnimation { proxy.scrollTo(StandardScrollAnchor.top, anchor: .top) }
            }
        }
    }

    /// 常設帯はこの1枚だけにする。以前は2枚を縦に積んで、一覧の見える高さを
    /// そのぶん削っていた。
    private var topBands: some View {
        VStack(spacing: 0) {
            // 表示中の一覧が最新でないときだけ出る。古い内容を最新と
            // 取り違えさせない。
            FreshnessBanner(freshness: viewModel.freshness, retry: { reload() })

            // 絞り込みはツールバーの奥で設定するので、効いていること自体に
            // 気づけない。効いているときだけ出して、その場で外せるようにする。
            ProgramSearchFilterSummaryBar(viewModel: searchViewModel)
        }
    }

    /// 先頭へ戻すときの目印は、いちばん上に出ているセクションに付ける。
    private func dayAnchorID(for day: ProgramDay) -> String {
        let isTop = expiringSoonPrograms.isEmpty && day.date == populatedDays.first?.date
        return isTop
            ? StandardScrollAnchor.top
            : "schedule.day.\(day.date.timeIntervalSinceReferenceDate)"
    }

    /// カードの横スクロール棚をやめ、本編と同じ行で並べる。視線の動きが
    /// 一方向になり、同じ情報量をより狭い面積で読める。
    private var expiringSoonSection: some View {
        Section {
            ForEach(expiringSoonPrograms, id: \.id) { program in
                programRow(program)
            }
        } header: {
            sectionHeader("まもなく配信終了", subtitle: "\(expiringSoonPrograms.count)本")
        }
    }

    @ViewBuilder
    private var searchSection: some View {
        Section {
            if searchedPrograms.isEmpty {
                // 「入力中」と「0 件」を描き分け、0 件のときは何で探した結果なのかと
                // 効いている絞り込みまで本文に出す。自前の表示に戻すとその区別が消える。
                ProgramSearchStatusView(viewModel: searchViewModel, onReset: { resetSearch() })
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            } else {
                ForEach(searchedPrograms, id: \.id) { program in
                    programRow(program)
                }
            }
        } header: {
            searchHeader
        }
    }

    private var searchHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("検索結果")
            Spacer(minLength: DS.Spacing.s)
            if searchViewModel.isFiltering {
                ProgressView()
                    .controlSize(.small)
            } else {
                Text("\(searchedPrograms.count)件")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(searchViewModel.accessibilitySummary)
    }

    private func programRow(_ program: TVerProgram) -> some View {
        let isFavorite = libraryStore.isFavorite(program)
        // 行そのものをリンクにする。行の中にボタンを置くと標準のハイライトも
        // 移動を示す山形も出せないので、ダウンロードはスワイプと長押しに回す。
        return NavigationLink(value: program) {
            MediaRow(
                title: displayTitle(for: program),
                subtitle: program.title,
                detail: detailText(for: program),
                thumbnailURL: program.thumbnailURL,
                badges: badges(for: program)
            )
        }
        .accessibilityLabel(accessibilityLabel(for: program))
        .accessibilityHint("ダブルタップして視聴画面を開きます")
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                libraryStore.toggleFavorite(program)
            } label: {
                Label(favoriteActionTitle(isFavorite), systemImage: isFavorite ? "heart.slash" : "heart")
            }
            // 赤は消える操作のための色。追加と削除を同じ色で出さない。
            .tint(.accentColor)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            downloadAction(for: program)
        }
        .contextMenu {
            Button {
                path.append(program)
            } label: {
                Label("視聴", systemImage: "play.fill")
            }
            Button {
                libraryStore.toggleFavorite(program)
            } label: {
                Label(favoriteActionTitle(isFavorite), systemImage: isFavorite ? "heart.slash" : "heart")
            }
            downloadAction(for: program)
            shareLink(for: program)
        }
    }

    /// 行から外したダウンロードのボタンの代わり。状態ごとに次の一手だけを
    /// 出し、失うものがある操作には必ず確認を挟む。
    @ViewBuilder
    private func downloadAction(for program: TVerProgram) -> some View {
        switch downloadCenter.state(for: program.id) {
        case .notDownloaded:
            Button {
                downloadCenter.start(program)
            } label: {
                Label(Vocabulary.Download.action, systemImage: "arrow.down.circle")
            }
        case .queued, .downloading:
            Button(role: .destructive) {
                confirmDownload(.runningDownload, for: program)
            } label: {
                Label(Vocabulary.Download.cancel, systemImage: "xmark.circle")
            }
        case .paused:
            downloadResumeAction(for: program)
        case .failed:
            Button {
                downloadCenter.retry(program.id)
            } label: {
                Label("もう一度\(Vocabulary.Download.action)", systemImage: "arrow.clockwise.circle")
            }
        case .downloaded:
            Button(role: .destructive) {
                confirmDownload(.savedDownload, for: program)
            } label: {
                Label(Vocabulary.Download.remove, systemImage: "trash")
            }
        }
    }

    /// アプリの終了で中断した転送は続きから戻せない。やり直しになることを
    /// 伝えてから始める。
    private func downloadResumeAction(for program: TVerProgram) -> some View {
        let isInterrupted = downloadCenter.isInterrupted(program.id)
        return Button {
            if isInterrupted {
                confirmDownload(.restartDownload, for: program)
            } else {
                downloadCenter.resume(program.id)
            }
        } label: {
            Label(
                isInterrupted ? "最初からやり直す" : Vocabulary.Download.resume,
                systemImage: isInterrupted ? "arrow.clockwise.circle" : "play.circle"
            )
        }
    }

    private func confirmDownload(
        _ target: DownloadConfirmation.Target,
        for program: TVerProgram
    ) {
        pendingDownload = PendingDownloadAction(
            program: program,
            confirmation: DownloadConfirmation(
                target: target,
                subject: displayTitle(for: program)
            )
        )
    }

    private func performDownloadAction(_ pending: PendingDownloadAction) {
        switch pending.confirmation.target {
        case .runningDownload:
            downloadCenter.cancel(pending.program.id)
        case .savedDownload:
            downloadCenter.delete(pending.program.id)
        case .restartDownload:
            downloadCenter.restart(pending.program)
        case .favorite, .allFavorites, .recent, .allRecents, .selection:
            // 見逃しタブはマイリスト・履歴・一括選択の確認を出さない。
            break
        }
    }

    private func shareLink(for program: TVerProgram) -> some View {
        let shareItem = ProgramShareItem(program: program)
        return ShareLink(
            item: shareItem.url,
            subject: Text(shareItem.subject),
            message: Text(shareItem.message)
        ) {
            Label("番組を共有", systemImage: "square.and.arrow.up")
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // iOS 16 で中身ごと消えないよう、配置は必ず ToolbarCompat を通す。
        if viewModel.isLoading, viewModel.hasPrograms {
            ToolbarItem(placement: ToolbarCompat.leading) {
                // 引き下げ以外の更新中は、一覧に重ねる浮遊チップではなく
                // ここで知らせる。行の上に何も乗らない。
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("更新中")
            }
        }
        ToolbarItem(placement: ToolbarCompat.trailing) {
            Menu {
                Section("絞り込み") {
                    Toggle("\(Vocabulary.Library.favorites)のみ", isOn: favoritesOnly)
                }
                Section("並び順") {
                    Picker("並び順", selection: $searchViewModel.sort) {
                        ForEach(ProgramSearchSort.allCases, id: \.self) { sort in
                            Text(sort.scheduleLabel).tag(sort)
                        }
                    }
                    .pickerStyle(.inline)
                }
                if activeControlCount > 0 {
                    Divider()
                    // 消えるのは絞り込み条件だけで、番組も履歴も失われない。
                    // 破壊的操作の赤は本当に消える操作のために取っておく。
                    Button {
                        resetSearch()
                    } label: {
                        Label("条件をクリア", systemImage: "arrow.uturn.backward")
                    }
                }
            } label: {
                // ツールバーの項目は標準で最小タップ範囲を持つ。自前で 44pt を
                // 足すと隣の項目と重なるので置かない。
                Label(
                    "絞り込みと並び順",
                    systemImage: activeControlCount > 0
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease.circle"
                )
                .labelStyle(.iconOnly)
                .symbolRenderingMode(.hierarchical)
            }
            .accessibilityLabel("絞り込みと並び順")
            .accessibilityValue(
                activeControlCount == 0 ? "条件なし" : "\(activeControlCount)件の条件を適用中"
            )
        }
    }

    /// 標準のセクションヘッダに戻す。自前の見出しは吸着したときに背景が付かず、
    /// 下の行が透けて重なって見えていた。
    private func sectionHeader(_ title: String, subtitle: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer(minLength: DS.Spacing.s)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
            }
        }
    }

    private var favoritesOnly: Binding<Bool> {
        Binding(
            get: { searchViewModel.filters.onlyFavorites },
            set: { searchViewModel.filters.onlyFavorites = $0 }
        )
    }

    private var populatedDays: [ProgramDay] {
        viewModel.days.filter { !$0.programs.isEmpty }
    }

    private var searchedPrograms: [TVerProgram] {
        ProgramSearchResultMapping.videoOnDemandPrograms(
            searchViewModel.results,
            in: viewModel.days
        )
    }

    /// The list switches to a flat result set as soon as any control is in use,
    /// so the day sections never show a partially filtered schedule.
    private var isSearchPresentationActive: Bool {
        !searchViewModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || activeControlCount > 0
    }

    private var activeControlCount: Int {
        var count = 0
        if searchViewModel.filters != .none { count += 1 }
        if searchViewModel.sort != .sourceOrder { count += 1 }
        return count
    }

    private var expiringSoonPrograms: [TVerProgram] {
        var seen = Set<String>()
        var result: [TVerProgram] = []
        for program in viewModel.days.flatMap(\.programs) {
            guard !badges(for: program).isEmpty, seen.insert(program.id).inserted else { continue }
            result.append(program)
            if result.count == Self.expiringSoonLimit { break }
        }
        return result
    }

    private func badges(for program: TVerProgram) -> [MediaBadge] {
        guard let remaining = ScheduleExpiry.remainingDays(for: program, now: now),
              ScheduleExpiry.isExpiringSoon(remaining)
        else { return [] }
        return [MediaBadge(.expiringSoon, text: ScheduleExpiry.countdownText(for: remaining))]
    }

    private func displayTitle(for program: TVerProgram) -> String {
        program.seriesTitle.isEmpty ? program.title : program.seriesTitle
    }

    private func detailText(for program: TVerProgram) -> String? {
        var parts: [String] = []
        if !program.broadcastLabel.isEmpty {
            parts.append(program.broadcastLabel)
        }
        // The badge already spells out an imminent deadline, so the label
        // would just repeat it in a quieter colour.
        if badges(for: program).isEmpty,
           let deadline = ScheduleExpiry.deadlineLabel(for: program, now: now) {
            parts.append(deadline)
        }
        if libraryStore.isFavorite(program) {
            parts.append(Vocabulary.Library.favorites)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ・ ")
    }

    private func favoriteActionTitle(_ isFavorite: Bool) -> String {
        isFavorite
            ? "\(Vocabulary.Library.favorites)から削除"
            : "\(Vocabulary.Library.favorites)に追加"
    }

    /// 読み上げも画面の文言と同じ語彙にそろえる。
    private func accessibilityLabel(for program: TVerProgram) -> String {
        var label = TVerAccessibilityText.program(program)
        if libraryStore.isFavorite(program) {
            label += "、\(Vocabulary.Library.favorites)に登録済み"
        }
        return label
    }

    /// 見出しは放送日で数える。深夜2時は前日の続きとして扱う。
    private func dayTitle(for date: Date) -> String {
        let calendar = BroadcastDay.calendar
        let today = BroadcastDay.day(containing: now, calendar: calendar)
        if calendar.isDate(date, inSameDayAs: today) { return "今日" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "昨日"
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale ?? Locale(identifier: "ja_JP")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "M月d日(E)"
        return formatter.string(from: date)
    }

    private func reload() {
        Task { await reloadAsync(forceRefresh: true) }
    }

    private func reloadAsync(forceRefresh: Bool) async {
        await viewModel.load(forceRefresh: forceRefresh)
        now = Date()
        refreshSearchIndex()
    }

    private func resetSearch() {
        searchViewModel.query = ""
        searchViewModel.filters = .none
        searchViewModel.sort = .sourceOrder
        searchViewModel.searchNow()
    }

    private func refreshSearchIndex() {
        searchViewModel.replaceIndex(
            .videoOnDemand(viewModel.days, favoriteProgramIDs: libraryStore.favoriteProgramIDs)
        )
    }
}

extension ProgramSearchSort {
    var scheduleLabel: String {
        switch self {
        case .sourceOrder: return "配信順"
        case .startTime: return "配信日が早い順"
        case .title: return "タイトル順"
        }
    }
}
