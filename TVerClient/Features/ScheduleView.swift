import AVKit
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

@MainActor
struct ScheduleView: View {
    @StateObject private var viewModel: ScheduleViewModel
    @StateObject private var searchViewModel: ProgramSearchViewModel
    @ObservedObject private var playbackController: PlaybackController
    @ObservedObject private var libraryStore: ProgramLibraryStore
    @State private var selectedProgram: TVerProgram?

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
            Group {
                if viewModel.showsInitialLoading {
                    ScheduleStatusView(
                        title: "番組表を読み込み中",
                        message: "最新の配信情報を取得しています。",
                        systemImage: "arrow.triangle.2.circlepath"
                    ) {
                        ProgressView()
                            .controlSize(.large)
                    }
                } else if let errorMessage = viewModel.errorMessage, viewModel.days.isEmpty {
                    ScheduleStatusView(
                        title: "番組表を読み込めませんでした",
                        message: errorMessage,
                        systemImage: "wifi.exclamationmark"
                    ) {
                        Button("再試行") {
                            Task {
                                await viewModel.load()
                                rebuildSearchIndex()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                } else if viewModel.days.allSatisfy({ $0.programs.isEmpty }) {
                    ScheduleStatusView(
                        title: "配信中の番組がありません",
                        message: "時間をおいて、もう一度更新してください。",
                        systemImage: "tv.slash"
                    ) {
                        Button("更新") {
                            Task {
                                await viewModel.load()
                                rebuildSearchIndex()
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                } else {
                    scheduleList
                }
            }
            .navigationTitle("見逃し")
            .background(Color(uiColor: .systemGroupedBackground))
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
            rebuildSearchIndex()
        }
        .onChange(of: viewModel.days) { _ in rebuildSearchIndex() }
        .onChange(of: libraryStore.favoritePrograms) { _ in rebuildSearchIndex() }
        .sheet(item: $selectedProgram) { program in
            PlaybackView(
                program: program,
                playbackController: playbackController,
                libraryStore: libraryStore
            )
        }
    }

    private var scheduleList: some View {
        ScrollView {
            LazyVStack(spacing: 24, pinnedViews: [.sectionHeaders]) {
                searchControls

                if isSearchPresentationActive {
                    if searchedPrograms.isEmpty && !searchViewModel.isFiltering {
                        searchEmptyState
                    } else {
                        searchResults
                    }
                } else {
                    daySections
                }
            }
            .padding(.bottom, 32)
        }
        .refreshable {
            await viewModel.load()
            rebuildSearchIndex()
        }
        .overlay(alignment: .top) {
            if viewModel.isLoading && !viewModel.days.isEmpty {
                ProgressView()
                    .padding(10)
                    .background(.regularMaterial, in: Circle())
                    .padding(.top, 8)
                    .accessibilityLabel("更新中")
            }
        }
    }

    private var searchControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("\(searchViewModel.results.count)件")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(searchViewModel.accessibilitySummary)
                    .accessibilityAddTraits(.updatesFrequently)

                if searchViewModel.isFiltering {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("検索中")
                }

                Spacer(minLength: 8)

                Menu {
                    Section("絞り込み") {
                        Toggle("お気に入りのみ", isOn: favoritesOnlyBinding)
                    }

                    Picker("並び順", selection: $searchViewModel.sort) {
                        ForEach(ProgramSearchSort.allCases, id: \.self) { sort in
                            Text(sort.scheduleLabel).tag(sort)
                        }
                    }

                    if searchViewModel.filters != .none || searchViewModel.sort != .sourceOrder {
                        Divider()
                        Button("絞り込みと並び順をリセット", role: .destructive) {
                            resetFiltersAndSort()
                        }
                    }
                } label: {
                    Label("絞り込みと並び順", systemImage: activeControlCount > 0
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease.circle")
                        .frame(minHeight: 44)
                }
                .accessibilityValue(activeControlCount == 0 ? "条件なし" : "\(activeControlCount)個の条件を適用中")
            }

            if searchViewModel.filters.onlyFavorites || searchViewModel.sort != .sourceOrder {
                HStack(spacing: 8) {
                    if searchViewModel.filters.onlyFavorites {
                        searchChip(title: "お気に入り", systemImage: "heart.fill") {
                            var filters = searchViewModel.filters
                            filters.onlyFavorites = false
                            searchViewModel.filters = filters
                        }
                    }
                    if searchViewModel.sort != .sourceOrder {
                        searchChip(title: searchViewModel.sort.scheduleLabel, systemImage: "arrow.up.arrow.down") {
                            searchViewModel.sort = .sourceOrder
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    private var daySections: some View {
        ForEach(viewModel.days.filter { !$0.programs.isEmpty }) { day in
            Section {
                LazyVStack(spacing: 12) {
                    ForEach(day.programs) { program in
                        programCard(program)
                    }
                }
                .padding(.horizontal, 16)
            } header: {
                DayHeader(date: day.date)
            }
        }
    }

    private var searchResults: some View {
        LazyVStack(spacing: 12) {
            ForEach(searchedPrograms) { program in
                programCard(program)
            }
        }
        .padding(.horizontal, 16)
    }

    private var searchEmptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 38, weight: .regular))
                .foregroundStyle(.blue)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text("条件に合う番組がありません")
                    .font(.title3.bold())
                Text("検索語や絞り込み条件を変えて、もう一度お試しください。")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button("検索条件をすべてリセット") { resetSearch() }
                .buttonStyle(.bordered)
                .controlSize(.large)
        }
        .padding(32)
        .frame(maxWidth: .infinity, minHeight: 320)
        .accessibilityElement(children: .contain)
    }

    private var searchedPrograms: [TVerProgram] {
        ProgramSearchResultMapping.videoOnDemandPrograms(
            searchViewModel.results,
            in: viewModel.days
        )
    }

    private var isSearchPresentationActive: Bool {
        !searchViewModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || searchViewModel.filters != .none
            || searchViewModel.sort != .sourceOrder
    }

    private var activeControlCount: Int {
        (searchViewModel.filters.onlyFavorites ? 1 : 0)
            + (searchViewModel.sort == .sourceOrder ? 0 : 1)
    }

    private var favoritesOnlyBinding: Binding<Bool> {
        Binding(
            get: { searchViewModel.filters.onlyFavorites },
            set: { newValue in
                var filters = searchViewModel.filters
                filters.onlyFavorites = newValue
                searchViewModel.filters = filters
            }
        )
    }

    private func programCard(_ program: TVerProgram) -> some View {
        ProgramCard(program: program, libraryStore: libraryStore) {
            DiagnosticLogStore.shared.record(
                .info,
                category: "playback",
                message: "VOD playback selected"
            )
            selectedProgram = program
        }
    }

    private func searchChip(
        title: String,
        systemImage: String,
        onRemove: @escaping () -> Void
    ) -> some View {
        Button(action: onRemove) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .padding(.leading, 12)
                .padding(.trailing, 8)
                .frame(minHeight: 36)
                .background(Color.blue.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title)を解除")
    }

    private func rebuildSearchIndex() {
        searchViewModel.replaceIndex(
            .videoOnDemand(
                viewModel.days,
                favoriteProgramIDs: Set(libraryStore.favoritePrograms.map(\.id))
            )
        )
    }

    private func resetFiltersAndSort() {
        searchViewModel.filters = .none
        searchViewModel.sort = .sourceOrder
        searchViewModel.searchNow()
    }

    private func resetSearch() {
        searchViewModel.query = ""
        searchViewModel.filters = .none
        searchViewModel.sort = .sourceOrder
        searchViewModel.searchNow()
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

struct DayHeader: View {
    let date: Date

    var body: some View {
        HStack {
            Text(date.formatted(.dateTime.month(.wide).day().weekday(.wide)))
                .font(.headline)
                .foregroundStyle(.primary)
            Spacer(minLength: 12)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .accessibilityAddTraits(.isHeader)
    }
}

struct ProgramCard: View {
    let program: TVerProgram
    @ObservedObject var libraryStore: ProgramLibraryStore
    let onWatch: () -> Void

    private var isFavorite: Bool { libraryStore.isFavorite(program) }
    private var shareItem: ProgramShareItem { ProgramShareItem(program: program) }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onWatch) {
                ViewThatFits(in: .horizontal) {
                    horizontalContent
                    verticalContent
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(CardButtonStyle())
            .accessibilityLabel(TVerAccessibilityText.program(program, isFavorite: isFavorite))
            .accessibilityHint("ダブルタップして視聴画面を開きます")

            Divider().padding(.leading, 12)
            HStack(spacing: 6) {
                Button { libraryStore.toggleFavorite(program) } label: {
                    Image(systemName: isFavorite ? "heart.fill" : "heart")
                        .foregroundStyle(isFavorite ? Color.red : Color.primary)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(isFavorite ? "お気に入りから削除" : "お気に入りに追加")

                ShareLink(item: shareItem.url, subject: Text(shareItem.subject), message: Text(shareItem.message)) {
                    Image(systemName: "square.and.arrow.up")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("番組を共有")

                Spacer(minLength: 8)
                Button(action: onWatch) {
                    Label("視聴", systemImage: "play.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(minHeight: 44)
                }
            }
            .padding(.horizontal, 8)
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(uiColor: .separator).opacity(0.22), lineWidth: 1)
        }
    }

    private var horizontalContent: some View {
        HStack(alignment: .top, spacing: 16) {
            ProgramThumbnail(url: program.thumbnailURL)
                .frame(width: 152, height: 86)
            details.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var verticalContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            ProgramThumbnail(url: program.thumbnailURL)
                .frame(maxWidth: .infinity)
                .aspectRatio(16 / 9, contentMode: .fit)
            details
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(program.seriesTitle)
                .font(.headline)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
            Text(program.title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
            Label(program.broadcastLabel, systemImage: "clock")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct ProgramThumbnail: View {
    let url: URL?

    var body: some View {
        CachedProgramImage(url: url, contentMode: .fill) {
            ZStack {
                thumbnailBackground
                Image(systemName: "photo")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .background(Color(uiColor: .tertiarySystemFill))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .clipped()
        .accessibilityHidden(true)
    }

    private var thumbnailBackground: some View {
        LinearGradient(
            colors: [Color(uiColor: .tertiarySystemFill), Color(uiColor: .secondarySystemFill)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

struct CardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.86 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
