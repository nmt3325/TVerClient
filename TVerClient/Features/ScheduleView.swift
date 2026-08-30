import AVKit
import Foundation
import SwiftUI

@MainActor
final class ScheduleViewModel: ObservableObject {
    @Published private(set) var days: [ProgramDay] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let service: any TVerCatalogServicing
    private let usesPreviewFallback: Bool
    private var hasLoaded = false

    init(service: any TVerCatalogServicing, usesPreviewFallback: Bool = true) {
        self.service = service
        self.usesPreviewFallback = usesPreviewFallback
    }

    var showsInitialLoading: Bool {
        isLoading && days.isEmpty
    }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await load()
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil

        do {
            let response = try await service.fetchSchedule()
            #if DEBUG
                days = response.isEmpty && usesPreviewFallback ? PreviewFixture.schedule : response
            #else
                days = response
            #endif
            hasLoaded = true
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            DiagnosticLogStore.shared.record(
                .error,
                category: "catalog",
                message: "Schedule loading failed",
                metadata: ["error": error.localizedDescription]
            )
        }

        isLoading = false
    }
}

/// Reads the free-text availability label the catalog returns
/// ("3月17日(月) 23:59まで") so a row can warn before a programme disappears.
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
    @State private var selectedProgram: TVerProgram?
    @State private var now = Date()

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
        NavigationStack {
            content
                .navigationTitle("見逃し")
                .toolbar { toolbarContent }
                .searchable(
                    text: $searchViewModel.query,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: Text(ProgramSearchAccessibilityText.fieldLabel)
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
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
        .sheet(item: $selectedProgram) { program in
            PlaybackView(
                program: program,
                playbackController: playbackController,
                libraryStore: libraryStore
            )
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.showsInitialLoading {
            ContentStatusView(.loading("最新の配信情報を取得しています。"))
        } else if let errorMessage = viewModel.errorMessage, viewModel.days.isEmpty {
            ContentStatusView(
                .failure(title: "番組表を読み込めませんでした", message: errorMessage),
                retry: { reload() }
            )
        } else if !hasAnyProgram {
            ContentStatusView(
                .empty(
                    title: "配信中の番組がありません",
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
        List {
            // One carousel, at the very top, for the episodes that are about
            // to disappear. Everything else stays a scannable vertical list.
            if !isSearchPresentationActive, !expiringSoonPrograms.isEmpty {
                expiringSoonCarousel
            }

            if isSearchPresentationActive {
                searchSection
            } else {
                ForEach(populatedDays, id: \.date) { day in
                    Section {
                        ForEach(day.programs, id: \.id) { program in
                            programRow(program)
                        }
                    } header: {
                        sectionHeader(dayTitle(for: day.date), subtitle: "\(day.programs.count)本")
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(DS.Palette.background)
        .refreshable { await reloadAsync() }
        .overlay(alignment: .top) { refreshIndicator }
    }

    private var expiringSoonCarousel: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: DS.Spacing.m) {
                    ForEach(expiringSoonPrograms, id: \.id) { program in
                        Button {
                            open(program)
                        } label: {
                            CompactMediaCell(
                                title: displayTitle(for: program),
                                subtitle: program.title,
                                thumbnailURL: program.thumbnailURL,
                                badges: badges(for: program)
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(accessibilityLabel(for: program))
                        .accessibilityHint("ダブルタップして視聴画面を開きます")
                    }
                }
                .padding(.horizontal, DS.Spacing.l)
                .padding(.vertical, DS.Spacing.s)
            }
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        } header: {
            sectionHeader("まもなく配信終了", subtitle: "\(expiringSoonPrograms.count)本")
        }
    }

    @ViewBuilder
    private var searchSection: some View {
        Section {
            if searchedPrograms.isEmpty, !searchViewModel.isFiltering {
                ContentStatusView(
                    .empty(
                        title: "条件に合う番組がありません",
                        message: "検索語や絞り込み条件を変えて、もう一度お試しください。",
                        systemImage: "magnifyingglass"
                    ),
                    retryTitle: "検索条件をリセット",
                    retry: { resetSearch() }
                )
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
        SectionHeader("検索結果") {
            if searchViewModel.isFiltering {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("検索中")
            } else {
                Text("\(searchedPrograms.count)件")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel(searchViewModel.accessibilitySummary)
        .listRowInsets(headerInsets)
        .listRowSeparator(.hidden)
        .textCase(nil)
    }

    private func programRow(_ program: TVerProgram) -> some View {
        let isFavorite = libraryStore.isFavorite(program)
        // The download control is a sibling rather than a nested button: a
        // button inside another button's label does not get its own tap
        // target in a List row.
        return HStack(spacing: DS.Spacing.s) {
            Button {
                open(program)
            } label: {
                MediaRow(
                    title: displayTitle(for: program),
                    subtitle: program.title,
                    detail: detailText(for: program),
                    thumbnailURL: program.thumbnailURL,
                    badges: badges(for: program)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel(for: program))
            .accessibilityHint("ダブルタップして視聴画面を開きます")

            DownloadButton(program: program)
        }
        .listRowInsets(
            EdgeInsets(top: 0, leading: DS.Spacing.l, bottom: 0, trailing: DS.Spacing.l)
        )
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                libraryStore.toggleFavorite(program)
            } label: {
                Label(
                    isFavorite ? "お気に入りから削除" : "お気に入りに追加",
                    systemImage: isFavorite ? "heart.slash" : "heart"
                )
            }
            .tint(DS.Palette.live)
        }
        .contextMenu {
            Button {
                open(program)
            } label: {
                Label("視聴", systemImage: "play.fill")
            }
            Button {
                libraryStore.toggleFavorite(program)
            } label: {
                Label(
                    isFavorite ? "お気に入りから削除" : "お気に入りに追加",
                    systemImage: isFavorite ? "heart.slash" : "heart"
                )
            }
            shareLink(for: program)
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
        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                Section("絞り込み") {
                    Toggle("お気に入りのみ", isOn: favoritesOnly)
                }
                Picker("並び順", selection: $searchViewModel.sort) {
                    ForEach(ProgramSearchSort.allCases, id: \.self) { sort in
                        Text(sort.scheduleLabel).tag(sort)
                    }
                }
                if activeControlCount > 0 {
                    Divider()
                    Button(role: .destructive) {
                        resetSearch()
                    } label: {
                        Label("検索条件をリセット", systemImage: "arrow.uturn.backward")
                    }
                }
            } label: {
                Image(
                    systemName: activeControlCount > 0
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease.circle"
                )
                .symbolRenderingMode(.hierarchical)
                .frame(width: DS.Size.minimumTapTarget, height: DS.Size.minimumTapTarget)
            }
            .accessibilityLabel("絞り込みと並び順")
            .accessibilityValue(
                activeControlCount == 0 ? "条件なし" : "\(activeControlCount)件の条件を適用中"
            )
        }
    }

    @ViewBuilder
    private var refreshIndicator: some View {
        if viewModel.isLoading, !viewModel.days.isEmpty {
            ProgressView()
                .padding(DS.Spacing.s)
                .background(.regularMaterial, in: Circle())
                .padding(.top, DS.Spacing.s)
                .accessibilityLabel("更新中")
        }
    }

    private func sectionHeader(_ title: String, subtitle: String?) -> some View {
        SectionHeader(title, subtitle: subtitle)
            .listRowInsets(headerInsets)
            .listRowSeparator(.hidden)
            .textCase(nil)
    }

    private var headerInsets: EdgeInsets {
        EdgeInsets(
            top: DS.Spacing.m,
            leading: DS.Spacing.l,
            bottom: DS.Spacing.xs,
            trailing: DS.Spacing.l
        )
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

    private var hasAnyProgram: Bool {
        viewModel.days.contains { !$0.programs.isEmpty }
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
            if result.count == 10 { break }
        }
        return result
    }

    private func badges(for program: TVerProgram) -> [MediaBadge] {
        guard let remaining = ScheduleExpiry.remainingDays(from: program.availableUntil, now: now),
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
        // The badge already spells out an imminent deadline, so the raw label
        // would just repeat it in a quieter colour.
        if badges(for: program).isEmpty, let availableUntil = program.availableUntil,
           !availableUntil.isEmpty {
            parts.append(availableUntil)
        }
        if libraryStore.isFavorite(program) {
            parts.append("お気に入り")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ・ ")
    }

    private func accessibilityLabel(for program: TVerProgram) -> String {
        TVerAccessibilityText.program(program, isFavorite: libraryStore.isFavorite(program))
    }

    private func dayTitle(for date: Date) -> String {
        let calendar = ScheduleExpiry.calendar
        if calendar.isDateInToday(date) { return "今日" }
        if calendar.isDateInYesterday(date) { return "昨日" }
        return date.formatted(.dateTime.month(.wide).day().weekday(.abbreviated))
    }

    private func open(_ program: TVerProgram) {
        DiagnosticLogStore.shared.record(
            .info,
            category: "playback",
            message: "VOD playback selected"
        )
        selectedProgram = program
    }

    private func reload() {
        Task { await reloadAsync() }
    }

    private func reloadAsync() async {
        await viewModel.load()
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
