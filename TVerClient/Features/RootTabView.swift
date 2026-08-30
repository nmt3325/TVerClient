import AVKit
import SwiftUI

@MainActor
struct RootTabView: View {
    @StateObject private var playbackController = PlaybackController()
    @StateObject private var libraryStore = ProgramLibraryStore()
    @StateObject private var diagnosticLogStore = DiagnosticLogStore.shared

    var body: some View {
        TabView {
            ProgramGuideView(
                viewModel: ProgramGuideViewModel(service: TVerAPIClient()),
                playbackController: playbackController,
                libraryStore: libraryStore
            )
            .tabItem {
                Label("番組表", systemImage: "rectangle.grid.3x2")
            }

            ScheduleView(
                viewModel: ScheduleViewModel(service: TVerAPIClient()),
                playbackController: playbackController,
                libraryStore: libraryStore
            )
            .tabItem {
                Label("見逃し", systemImage: "play.rectangle.on.rectangle")
            }

            LibraryView(
                libraryStore: libraryStore,
                playbackController: playbackController
            )
            .tabItem {
                Label("ライブラリ", systemImage: "books.vertical")
            }

            LiveView(
                viewModel: LiveViewModel(service: TVerAPIClient()),
                playbackController: playbackController
            )
            .tabItem {
                Label("ライブ", systemImage: "dot.radiowaves.left.and.right")
            }

            DiagnosticsView(logStore: diagnosticLogStore)
                .tabItem {
                    Label("診断", systemImage: "stethoscope")
                }
        }
        .tint(.blue)
    }
}

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
private struct ScheduleView: View {
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

private extension ProgramSearchSort {
    var scheduleLabel: String {
        switch self {
        case .sourceOrder: return "配信順"
        case .startTime: return "配信日が早い順"
        case .title: return "タイトル順"
        }
    }
}

@MainActor
final class LiveViewModel: ObservableObject {
    @Published private(set) var channels: [TVerLiveChannel] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    private let service: any TVerLiveServicing
    private let usesPreviewFallback: Bool
    private var hasLoaded = false

    init(service: any TVerLiveServicing, usesPreviewFallback: Bool = true) {
        self.service = service
        self.usesPreviewFallback = usesPreviewFallback
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
            let response = try await service.fetchLiveChannels()
            #if DEBUG
                channels = response.isEmpty && usesPreviewFallback ? PreviewFixture.liveChannels : response
            #else
                channels = response
            #endif
            hasLoaded = true
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            DiagnosticLogStore.shared.record(
                .error,
                category: "live-catalog",
                message: "Live channel loading failed",
                metadata: ["error": error.localizedDescription]
            )
        }
        isLoading = false
    }
}

private struct LiveView: View {
    @StateObject private var viewModel: LiveViewModel
    @ObservedObject private var playbackController: PlaybackController
    @State private var selectedChannel: TVerLiveChannel?

    init(viewModel: LiveViewModel, playbackController: PlaybackController) {
        _viewModel = StateObject(wrappedValue: viewModel)
        self.playbackController = playbackController
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoading && viewModel.channels.isEmpty {
                    ScheduleStatusView(title: "ライブを読み込み中", message: "公式TVerのリアルタイム配信情報を取得しています。", systemImage: "dot.radiowaves.left.and.right") {
                        ProgressView().controlSize(.large)
                    }
                } else if let error = viewModel.errorMessage, viewModel.channels.isEmpty {
                    ScheduleStatusView(title: "ライブを読み込めませんでした", message: error, systemImage: "wifi.exclamationmark") {
                        Button("再試行") { Task { await viewModel.load() } }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                    }
                } else if viewModel.channels.isEmpty {
                    ScheduleStatusView(title: "ライブ配信がありません", message: "時間をおいて、もう一度更新してください。", systemImage: "tv.slash") {
                        Button("更新") { Task { await viewModel.load() } }
                            .buttonStyle(.bordered).controlSize(.large)
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 14) {
                            ForEach(viewModel.channels) { channel in
                                LiveChannelCard(channel: channel) {
                                    DiagnosticLogStore.shared.record(
                                        .info,
                                        category: "playback",
                                        message: "Live playback selected"
                                    )
                                    selectedChannel = channel
                                }
                            }
                        }
                        .padding(16)
                    }
                    .refreshable { await viewModel.load() }
                    .overlay(alignment: .top) {
                        if viewModel.isLoading {
                            ProgressView().padding(10).background(.regularMaterial, in: Circle()).padding(.top, 8)
                                .accessibilityLabel("更新中")
                        }
                    }
                }
            }
            .navigationTitle("ライブ")
            .background(Color(uiColor: .systemGroupedBackground))
        }
        .task { await viewModel.loadIfNeeded() }
        .sheet(item: $selectedChannel) { channel in
            LivePlaybackView(channel: channel, playbackController: playbackController)
        }
    }
}

private struct LiveChannelCard: View {
    let channel: TVerLiveChannel
    let onWatch: () -> Void

    private var shareItem: ProgramShareItem { ProgramShareItem(channel: channel) }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onWatch) {
                HStack(alignment: .top, spacing: 14) {
                    ProgramThumbnail(url: channel.currentProgram?.thumbnailURL ?? channel.iconURL)
                        .frame(width: 136, height: 77)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(channel.name).font(.headline).foregroundStyle(.primary)
                            Spacer(minLength: 6)
                            Text(channel.state.label)
                                .font(.caption.bold())
                                .foregroundStyle(channel.state == .onAir ? Color.red : Color.secondary)
                        }
                        Text(channel.currentProgram?.seriesTitle ?? "番組情報なし")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(2)
                        if let program = channel.currentProgram {
                            Text(program.timeLabel).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(channel.currentProgram?.title ?? "現在の番組を取得できませんでした。")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(CardButtonStyle())
            .disabled(!channel.isPlayable)
            .opacity(channel.isPlayable ? 1 : 0.72)
            .accessibilityLabel(TVerAccessibilityText.live(channel: channel))
            .accessibilityHint(channel.isPlayable ? "ダブルタップしてライブを視聴します" : "現在は視聴できません")

            Divider().padding(.leading, 12)
            HStack(spacing: 8) {
                ShareLink(item: shareItem.url, subject: Text(shareItem.subject), message: Text(shareItem.message)) {
                    Label("共有", systemImage: "square.and.arrow.up")
                        .frame(minWidth: 44, minHeight: 44)
                }
                Spacer(minLength: 8)
                Button(action: onWatch) {
                    Label(channel.isPlayable ? "視聴" : "視聴不可", systemImage: "play.fill")
                        .frame(minHeight: 44)
                }
                .disabled(!channel.isPlayable)
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12)
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(Color(uiColor: .separator).opacity(0.22)) }
    }
}

private struct LivePlaybackView: View {
    let channel: TVerLiveChannel
    @ObservedObject var playbackController: PlaybackController
    @StateObject private var pictureInPicture = PictureInPictureCoordinator()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private var shareItem: ProgramShareItem { ProgramShareItem(channel: channel) }
    private var isCurrent: Bool { playbackController.currentLiveChannel?.id == channel.id }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    PlaybackVideoSurface(
                        player: playbackController.player,
                        pictureInPicture: pictureInPicture,
                        accessibilityLabel: "\(channel.name)のライブ動画プレイヤー"
                    )

                    VStack(alignment: .leading, spacing: 7) {
                        Label("配信中", systemImage: "dot.radiowaves.left.and.right")
                            .font(.caption.bold()).foregroundStyle(.red)
                        Text(channel.currentProgram?.seriesTitle ?? "TVer リアルタイム配信").font(.title2.bold())
                        Text(channel.currentProgram?.title ?? channel.name).foregroundStyle(.secondary)
                        if let program = channel.currentProgram {
                            Label(program.timeLabel, systemImage: "clock").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }

                    playbackStatus

                    PictureInPictureControl(coordinator: pictureInPicture)

                    ShareLink(item: shareItem.url, subject: Text(shareItem.subject), message: Text(shareItem.message)) {
                        Label("このライブ配信を共有", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    if !(isCurrent && playbackController.errorPresentation != nil) {
                        Button { openURL(channel.webURL) } label: {
                            Label("TVer公式ライブページで開く", systemImage: "safari")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered).controlSize(.large)
                    }
                }
                .padding(20)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(channel.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { dismiss() }.frame(minWidth: 44, minHeight: 44)
                }
            }
        }
        .task(id: channel.id) { await playbackController.playLive(channel) }
    }

    @ViewBuilder
    private var playbackStatus: some View {
        if isCurrent, let presentation = playbackController.errorPresentation {
            PlaybackFailureView(presentation: presentation, officialURL: channel.webURL) {
                Task { await playbackController.playLive(channel) }
            }
        } else if isCurrent, playbackController.state == .resolving {
            HStack { Spacer(); ProgressView("公式配信URLを確認中"); Spacer() }
                .frame(minHeight: 44)
                .accessibilityLabel("ライブ配信を準備中")
        } else {
            Button { playbackController.togglePlayback() } label: {
                Label(
                    playbackController.isPlaying ? "一時停止" : "再生",
                    systemImage: playbackController.isPlaying ? "pause.fill" : "play.fill"
                )
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
        }
    }
}

private struct DayHeader: View {
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

private struct ProgramCard: View {
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

private struct ProgramThumbnail: View {
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

private struct CardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.86 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct PlaybackView: View {
    let program: TVerProgram
    @ObservedObject var playbackController: PlaybackController
    @ObservedObject var libraryStore: ProgramLibraryStore
    @StateObject private var pictureInPicture = PictureInPictureCoordinator()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private var isCurrent: Bool { playbackController.currentProgram?.id == program.id }
    private var isFavorite: Bool { libraryStore.isFavorite(program) }
    private var shareItem: ProgramShareItem { ProgramShareItem(program: program) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    PlaybackVideoSurface(
                        player: playbackController.player,
                        pictureInPicture: pictureInPicture,
                        accessibilityLabel: "\(program.seriesTitle)の動画プレイヤー"
                    )

                    VStack(alignment: .leading, spacing: 8) {
                        Text(program.seriesTitle).font(.title2.bold())
                        Text(program.title).font(.body).foregroundStyle(.secondary)
                        Label(program.broadcastLabel, systemImage: "clock")
                            .font(.subheadline).foregroundStyle(.secondary)
                        if let availableUntil = program.availableUntil, !availableUntil.isEmpty {
                            Label("配信期限 \(availableUntil)", systemImage: "calendar.badge.clock")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }

                    HStack(spacing: 8) {
                        Button { libraryStore.toggleFavorite(program) } label: {
                            Label(
                                isFavorite ? "お気に入りから削除" : "お気に入りに追加",
                                systemImage: isFavorite ? "heart.fill" : "heart"
                            )
                            .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .tint(isFavorite ? .red : .accentColor)

                        ShareLink(item: shareItem.url, subject: Text(shareItem.subject), message: Text(shareItem.message)) {
                            Label("共有", systemImage: "square.and.arrow.up")
                                .frame(minWidth: 72, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                    }
                    .controlSize(.large)

                    playbackStatus

                    PictureInPictureControl(coordinator: pictureInPicture)

                    if !(isCurrent && playbackController.errorPresentation != nil) {
                        Button { openURL(program.webURL) } label: {
                            Label("TVer公式ページで開く", systemImage: "safari")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                }
                .padding(20)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("視聴")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { dismiss() }.frame(minWidth: 44, minHeight: 44)
                }
            }
        }
        .task(id: program.id) {
            libraryStore.recordRecentlyViewed(program)
            await playbackController.play(program)
        }
    }

    @ViewBuilder
    private var playbackStatus: some View {
        if isCurrent, let presentation = playbackController.errorPresentation {
            PlaybackFailureView(presentation: presentation, officialURL: program.webURL) {
                libraryStore.recordRecentlyViewed(program)
                Task { await playbackController.play(program) }
            }
        } else if isCurrent, playbackController.state == .resolving {
            HStack { Spacer(); ProgressView("再生を準備中"); Spacer() }
                .frame(minHeight: 44)
                .accessibilityLabel("番組の再生を準備中")
        } else {
            PlaybackTimelineView(playbackController: playbackController)
            playbackControls
            if isCurrent, playbackController.state == .ended {
                Label("再生が終了しました", systemImage: "checkmark.circle")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    private var playbackControls: some View {
        HStack(spacing: 20) {
            playbackButton(title: "15秒戻す", systemImage: "gobackward.15", offset: -15)
            Button { playbackController.togglePlayback() } label: {
                Image(systemName: playbackController.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .frame(width: 56, height: 56)
                    .background(Color.blue, in: Circle())
                    .foregroundStyle(.white)
            }
            .accessibilityLabel(playbackController.isPlaying ? "一時停止" : "再生")
            playbackButton(title: "15秒送る", systemImage: "goforward.15", offset: 15)
        }
        .frame(maxWidth: .infinity)
    }

    private func playbackButton(title: String, systemImage: String, offset: TimeInterval) -> some View {
        Button { playbackController.seek(by: offset) } label: {
            Image(systemName: systemImage)
                .font(.title2)
                .frame(width: 52, height: 52)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(
            TVerAccessibilityText.playbackTime(
                elapsed: playbackController.player.currentTime().seconds,
                duration: playbackController.player.currentItem?.duration.seconds
            )
        )
    }
}

private enum ProgramLibrarySection: String, CaseIterable, Identifiable {
    case favorites = "お気に入り"
    case recents = "最近見た"
    var id: String { rawValue }
}

private struct LibraryView: View {
    @ObservedObject var libraryStore: ProgramLibraryStore
    @ObservedObject var playbackController: PlaybackController
    @State private var section: ProgramLibrarySection = .favorites
    @State private var selectedProgram: TVerProgram?
    @State private var showsClearConfirmation = false

    private var programs: [TVerProgram] {
        section == .favorites ? libraryStore.favoritePrograms : libraryStore.recentPrograms
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("ライブラリ表示", selection: $section) {
                    ForEach(ProgramLibrarySection.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                if programs.isEmpty {
                    ScheduleStatusView(
                        title: section == .favorites ? "お気に入りはまだありません" : "最近見た番組はありません",
                        message: section == .favorites
                            ? "番組カードのハートを押すと、ここからすぐに視聴できます。"
                            : "番組を再生すると、ここに履歴が表示されます。",
                        systemImage: section == .favorites ? "heart" : "clock.arrow.circlepath"
                    ) {
                        EmptyView()
                    }
                } else {
                    List {
                        ForEach(programs) { program in
                            LibraryProgramRow(program: program) {
                                DiagnosticLogStore.shared.record(
                                    .info,
                                    category: "playback",
                                    message: "Library playback selected"
                                )
                                selectedProgram = program
                            }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) { remove(program) } label: {
                                        Label("削除", systemImage: "trash")
                                    }
                                }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("ライブラリ")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("すべて消去", role: .destructive) { showsClearConfirmation = true }
                        .frame(minHeight: 44)
                        .disabled(programs.isEmpty)
                }
            }
        }
        .confirmationDialog(
            "\(section.rawValue)をすべて消去しますか？",
            isPresented: $showsClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("すべて消去", role: .destructive) { clearCurrentSection() }
            Button("キャンセル", role: .cancel) {}
        }
        .sheet(item: $selectedProgram) { program in
            PlaybackView(
                program: program,
                playbackController: playbackController,
                libraryStore: libraryStore
            )
        }
    }

    private func remove(_ program: TVerProgram) {
        if section == .favorites { libraryStore.removeFavorite(program) }
        else { libraryStore.removeRecentProgram(program) }
    }

    private func clearCurrentSection() {
        if section == .favorites { libraryStore.clearFavorites() }
        else { libraryStore.clearRecentPrograms() }
    }
}

private struct LibraryProgramRow: View {
    let program: TVerProgram
    let onWatch: () -> Void

    var body: some View {
        Button(action: onWatch) {
            HStack(spacing: 12) {
                ProgramThumbnail(url: program.thumbnailURL)
                    .frame(width: 112, height: 63)
                VStack(alignment: .leading, spacing: 4) {
                    Text(program.seriesTitle).font(.headline).lineLimit(2)
                    Text(program.title).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    Label(program.broadcastLabel, systemImage: "clock")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "play.circle.fill")
                    .font(.title2).foregroundStyle(.blue)
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(TVerAccessibilityText.program(program))
        .accessibilityHint("ダブルタップして再生します。左にスワイプすると削除できます")
    }
}

private struct ScheduleStatusView<Accessory: View>: View {
    let title: String
    let message: String
    let systemImage: String
    @ViewBuilder let accessory: Accessory

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 42, weight: .regular))
                .foregroundStyle(.blue)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text(title)
                    .font(.title3.bold())
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            accessory
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview("番組表") {
    RootTabView()
}
