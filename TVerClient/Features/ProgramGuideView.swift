import AVKit
import SwiftUI
import UIKit

@MainActor
final class ProgramGuideViewModel: ObservableObject {
    @Published private(set) var guide: [TVerGuideChannel] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    /// When the guide currently on screen was produced by a successful fetch.
    @Published private(set) var lastUpdatedAt: Date?

    /// True while the rows on screen come from the offline copy rather than a
    /// fresh response. Stale data is never presented silently.
    @Published private(set) var isShowingCachedData = false

    private let service: any TVerProgramGuideServicing
    private let usesPreviewFallback: Bool
    private let snapshotStore: ProgramGuideSnapshotStore?
    private let now: () -> Date
    private var hasLoaded = false
    private var didRestoreSnapshot = false

    init(
        service: any TVerProgramGuideServicing,
        usesPreviewFallback: Bool = true,
        snapshotStore: ProgramGuideSnapshotStore? = ProgramGuideSnapshotStore.shared,
        now: @escaping () -> Date = Date.init
    ) {
        self.service = service
        self.usesPreviewFallback = usesPreviewFallback
        self.snapshotStore = snapshotStore
        self.now = now
    }

    var showsInitialLoading: Bool {
        isLoading && guide.isEmpty
    }

    var hasPrograms: Bool {
        guide.contains { !$0.programs.isEmpty }
    }

    /// Banner text for the guide screen, or nil while the data is live.
    var offlineNotice: String? {
        guard isShowingCachedData else { return nil }
        return ProgramGuideOfflineNotice.text(lastUpdatedAt: lastUpdatedAt, now: now())
    }

    func loadIfNeeded() async {
        await restoreCachedGuideIfNeeded()
        guard !hasLoaded else { return }
        await load()
    }

    /// Draws the last known guide immediately so a cold launch is not blank,
    /// and keeps it flagged as cached until the revalidation behind it lands.
    func restoreCachedGuideIfNeeded() async {
        guard !didRestoreSnapshot else { return }
        didRestoreSnapshot = true
        guard !hasLoaded, guide.isEmpty, let snapshotStore else { return }
        guard let snapshot = await snapshotStore.load(at: now()) else { return }
        guard snapshot.guide.contains(where: { !$0.programs.isEmpty }) else { return }
        guide = snapshot.guide
        lastUpdatedAt = snapshot.savedAt
        isShowingCachedData = true
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        do {
            let response = try await service.fetchProgramGuide(forceRefresh: hasLoaded)
            #if DEBUG
                let resolved = response.contains(where: { !$0.programs.isEmpty }) || !usesPreviewFallback
                    ? response : PreviewFixture.programGuide
            #else
                let resolved = response
            #endif
            guide = resolved
            hasLoaded = true
            let updatedAt = now()
            lastUpdatedAt = updatedAt
            isShowingCachedData = false
            if let snapshotStore, resolved.contains(where: { !$0.programs.isEmpty }) {
                await snapshotStore.save(resolved, at: updatedAt)
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            // Whatever is still on screen came from an earlier fetch, so label
            // it instead of letting stale rows pass for live ones.
            isShowingCachedData = !guide.isEmpty
            DiagnosticLogStore.shared.record(
                .error,
                category: "program-guide",
                message: "Program guide loading failed",
                metadata: ["error": error.localizedDescription]
            )
        }
        isLoading = false
    }
}

struct ProgramGuideView: View {
    @StateObject private var viewModel: ProgramGuideViewModel
    @ObservedObject private var playbackController: PlaybackController
    @ObservedObject private var libraryStore: ProgramLibraryStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedDate = ProgramGuideMetrics.calendar.startOfDay(for: Date())
    @State private var selectedProgram: ProgramGuideSelection?
    @State private var scrollToNowToken = 0
    /// Persisted so the grid reopens at the density the user chose.
    @AppStorage("guide.pointsPerMinute") private var storedPointsPerMinute = Double(GuideZoom.defaultPointsPerMinute)
    @AppStorage("guide.hiddenChannelIDs") private var hiddenChannelIDsText = ""
    private let notificationScheduler: ProgramNotificationScheduler
    private let catchUpLookup: GuideCatchUpLookup

    init(
        viewModel: ProgramGuideViewModel,
        playbackController: PlaybackController,
        libraryStore: ProgramLibraryStore,
        notificationScheduler: ProgramNotificationScheduler = ProgramNotificationScheduler(),
        catchUpService: any TVerCatchUpLookupServicing = TVerAPIClient()
    ) {
        _viewModel = StateObject(wrappedValue: viewModel)
        self.playbackController = playbackController
        self.libraryStore = libraryStore
        self.notificationScheduler = notificationScheduler
        catchUpLookup = GuideCatchUpLookup(service: catchUpService)
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.showsInitialLoading {
                    ProgramGuideStatusView(
                        title: "番組表を読み込み中",
                        message: "各放送局の番組情報を取得しています。",
                        systemImage: "rectangle.grid.3x2"
                    ) { ProgressView().controlSize(.large) }
                } else if let error = viewModel.errorMessage, viewModel.guide.isEmpty {
                    ProgramGuideStatusView(
                        title: "番組表を読み込めませんでした",
                        message: error,
                        systemImage: "wifi.exclamationmark"
                    ) {
                        Button("再試行") { Task { await viewModel.load() } }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .frame(minHeight: ProgramGuideMetrics.minimumTapTarget)
                    }
                } else if !viewModel.hasPrograms {
                    ProgramGuideStatusView(
                        title: "番組情報がありません",
                        message: "時間をおいて、もう一度更新してください。",
                        systemImage: "tv.slash"
                    ) {
                        Button("更新") { Task { await viewModel.load() } }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            .frame(minHeight: ProgramGuideMetrics.minimumTapTarget)
                    }
                } else {
                    guideContent
                }
            }
            .navigationTitle("番組表")
            .navigationBarTitleDisplayMode(.inline)
            .background(Color(uiColor: .systemGroupedBackground))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { zoom(to: GuideZoom.nextStop(below: pointsPerMinute)) } label: {
                        Image(systemName: "minus.magnifyingglass")
                            .frame(
                                width: ProgramGuideMetrics.minimumTapTarget,
                                height: ProgramGuideMetrics.minimumTapTarget
                            )
                    }
                    .disabled(!canZoomOut)
                    .accessibilityLabel("番組表を縮小")
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button { zoom(to: GuideZoom.nextStop(above: pointsPerMinute)) } label: {
                        Image(systemName: "plus.magnifyingglass")
                            .frame(
                                width: ProgramGuideMetrics.minimumTapTarget,
                                height: ProgramGuideMetrics.minimumTapTarget
                            )
                    }
                    .disabled(!canZoomIn)
                    .accessibilityLabel("番組表を拡大")
                }
                ToolbarItem(placement: .topBarTrailing) { channelFilterMenu }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await viewModel.load() } } label: {
                        if viewModel.isLoading {
                            ProgressView().frame(width: ProgramGuideMetrics.minimumTapTarget, height: ProgramGuideMetrics.minimumTapTarget)
                        } else {
                            Image(systemName: "arrow.clockwise").frame(width: ProgramGuideMetrics.minimumTapTarget, height: ProgramGuideMetrics.minimumTapTarget)
                        }
                    }
                    .disabled(viewModel.isLoading)
                    .accessibilityLabel(viewModel.isLoading ? "更新中" : "番組表を更新")
                }
            }
        }
        .task { await viewModel.loadIfNeeded() }
        .onChange(of: viewModel.guide) { guide in
            let dates = ProgramGuideMetrics.dates(in: guide)
            if !dates.contains(where: { ProgramGuideMetrics.isSameDay($0, selectedDate) }),
               let preferred = ProgramGuideMetrics.preferredDate(in: dates)
            {
                selectedDate = preferred
            }
        }
        .sheet(item: $selectedProgram) { selection in
            ProgramGuideDetailSheet(
                selection: selection,
                playbackController: playbackController,
                libraryStore: libraryStore,
                notificationScheduler: notificationScheduler,
                catchUpLookup: catchUpLookup
            )
            .presentationDetents([.medium, .large])
        }
    }

    private var guideContent: some View {
        VStack(spacing: 0) {
            if let notice = viewModel.offlineNotice {
                ProgramGuideOfflineBanner(message: notice)
                Divider()
            }
            ProgramGuideDatePicker(
                dates: ProgramGuideMetrics.dates(in: viewModel.guide),
                selectedDate: $selectedDate
            )
            Divider()
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    ProgramGuideAccessibleList(
                        guide: visibleGuide,
                        selectedDate: selectedDate,
                        onSelect: selectProgram
                    )
                } else {
                    ProgramGuideGrid(
                        guide: visibleGuide,
                        selectedDate: selectedDate,
                        pointsPerMinute: pointsPerMinuteBinding,
                        scrollToNowToken: scrollToNowToken,
                        onSelect: selectProgram
                    )
                }
            }
            .id(selectedDate)
        }
        .overlay(alignment: .top) {
            if viewModel.isLoading, !viewModel.guide.isEmpty {
                ProgressView()
                    .padding(9)
                    .background(.regularMaterial, in: Circle())
                    .padding(.top, 8)
                    .accessibilityLabel("更新中")
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if hasTodayInGuide {
                Button(action: jumpToNow) {
                    Label("今", systemImage: "clock.arrow.circlepath")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, DS.Spacing.m)
                        .frame(minHeight: ProgramGuideMetrics.minimumTapTarget)
                        .background(.regularMaterial, in: Capsule())
                        .overlay { Capsule().stroke(Color(uiColor: .separator).opacity(0.4)) }
                }
                .buttonStyle(.plain)
                .padding(DS.Spacing.l)
                .accessibilityLabel("現在時刻に戻る")
            }
        }
    }

    /// Zoom of the grid, in points per broadcast minute.
    private var pointsPerMinute: CGFloat {
        GuideZoom.clamp(CGFloat(storedPointsPerMinute))
    }

    private var pointsPerMinuteBinding: Binding<CGFloat> {
        Binding(
            get: { GuideZoom.clamp(CGFloat(storedPointsPerMinute)) },
            set: { storedPointsPerMinute = Double(GuideZoom.clamp($0)) }
        )
    }

    private var canZoomIn: Bool { pointsPerMinute < GuideZoom.maximumPointsPerMinute - 0.01 }

    private var canZoomOut: Bool { pointsPerMinute > GuideZoom.minimumPointsPerMinute + 0.01 }

    private var hiddenChannelIDs: Set<String> {
        Set(hiddenChannelIDsText.split(separator: "\n").map(String.init))
    }

    private var visibleGuide: [TVerGuideChannel] {
        let hidden = hiddenChannelIDs
        guard !hidden.isEmpty else { return viewModel.guide }
        let filtered = viewModel.guide.filter { !hidden.contains($0.channel.id) }
        // Hiding every channel would leave a blank grid with no way back.
        return filtered.isEmpty ? viewModel.guide : filtered
    }

    private var hasTodayInGuide: Bool {
        ProgramGuideMetrics.dates(in: viewModel.guide)
            .contains { ProgramGuideMetrics.calendar.isDateInToday($0) }
    }

    private var channelFilterMenu: some View {
        Menu {
            Button { hiddenChannelIDsText = "" } label: {
                Label("すべて表示", systemImage: "eye")
            }
            .disabled(hiddenChannelIDs.isEmpty)
            Divider()
            ForEach(viewModel.guide) { item in
                Button { toggleChannel(item.channel.id) } label: {
                    if hiddenChannelIDs.contains(item.channel.id) {
                        Text(item.channel.name)
                    } else {
                        Label(item.channel.name, systemImage: "checkmark")
                    }
                }
            }
        } label: {
            Image(systemName: hiddenChannelIDs.isEmpty
                ? "line.3.horizontal.decrease.circle"
                : "line.3.horizontal.decrease.circle.fill")
                .frame(
                    width: ProgramGuideMetrics.minimumTapTarget,
                    height: ProgramGuideMetrics.minimumTapTarget
                )
        }
        .accessibilityLabel("チャンネルを絞り込む")
    }

    private func zoom(to value: CGFloat) {
        withAnimation(.easeInOut(duration: 0.18)) {
            storedPointsPerMinute = Double(GuideZoom.clamp(value))
        }
    }

    private func toggleChannel(_ channelID: String) {
        var hidden = hiddenChannelIDs
        if hidden.contains(channelID) {
            hidden.remove(channelID)
        } else {
            hidden.insert(channelID)
        }
        hiddenChannelIDsText = hidden.sorted().joined(separator: "\n")
    }

    /// Jumps to the live edge, switching to today first when the user is
    /// looking at another day.
    private func jumpToNow() {
        let today = ProgramGuideMetrics.dates(in: viewModel.guide)
            .first { ProgramGuideMetrics.calendar.isDateInToday($0) }
        if let today, !ProgramGuideMetrics.isSameDay(today, selectedDate) {
            selectedDate = today
        } else {
            scrollToNowToken += 1
        }
    }

    private func selectProgram(channel: TVerLiveChannel, program: TVerLiveProgram) {
        selectedProgram = ProgramGuideSelection(channel: channel, program: program)
    }
}

private struct ProgramGuideDatePicker: View {
    let dates: [Date]
    @Binding var selectedDate: Date
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(dates, id: \.self) { date in
                        let isSelected = ProgramGuideMetrics.isSameDay(date, selectedDate)
                        Button {
                            selectedDate = date
                        } label: {
                            VStack(spacing: 2) {
                                Text(date, format: .dateTime.month().day())
                                    .font(.subheadline.weight(.semibold))
                                Text(relativeLabel(for: date))
                                    .font(.caption)
                            }
                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(
                                minWidth: dynamicTypeSize.isAccessibilitySize ? 96 : 68,
                                minHeight: dynamicTypeSize.isAccessibilitySize ? 64 : 44
                            )
                            .padding(.horizontal, 4)
                            .background(isSelected ? Color.accentColor : Color(uiColor: .secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay {
                                if !isSelected {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(Color(uiColor: .separator).opacity(0.35))
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(accessibilityDate(date))
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                        .id(date)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .onAppear {
                DispatchQueue.main.async {
                    proxy.scrollTo(selectedDate, anchor: .center)
                }
            }
            .onChange(of: selectedDate) { date in
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(date, anchor: .center)
                }
            }
        }
    }

    private func relativeLabel(for date: Date) -> String {
        if ProgramGuideMetrics.calendar.isDateInToday(date) {
            return "今日"
        }
        if ProgramGuideMetrics.calendar.isDateInTomorrow(date) {
            return "明日"
        }
        if ProgramGuideMetrics.calendar.isDateInYesterday(date) {
            return "昨日"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")
        formatter.dateFormat = "EEE"
        return formatter.string(from: date)
    }

    private func accessibilityDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")
        formatter.dateFormat = "M月d日EEEE"
        return TVerAccessibilityText.guideDate(date, relativeLabel: relativeLabel(for: date))
    }
}

private struct ProgramGuideAccessibleList: View {
    let guide: [TVerGuideChannel]
    let selectedDate: Date
    let onSelect: (TVerLiveChannel, TVerLiveProgram) -> Void
    @EnvironmentObject private var availabilityStore: CatchUpAvailabilityStore

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(guide) { item in
                    let programs = ProgramGuideMetrics.programs(item.programs, on: selectedDate)
                        .sorted { $0.startAt < $1.startAt }
                    if !programs.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(item.channel.name, systemImage: "tv")
                                .font(.headline)
                                .accessibilityAddTraits(.isHeader)
                                .onAppear {
                                    availabilityStore.prefetch(
                                        channelID: item.channel.id,
                                        programs: programs
                                    )
                                }

                            ForEach(programs) { program in
                                let now = Date()
                                let isOnAir = program.startAt <= now && now < program.endAt
                                let availability = availabilityStore.availability(
                                    channelID: item.channel.id,
                                    program: program,
                                    channelState: item.channel.state,
                                    now: now
                                )
                                let hasNothingToPlay = GuideAvailabilityPresentation
                                    .hasNothingToPlay(isOnAir: isOnAir, availability: availability)
                                Button {
                                    onSelect(item.channel, program)
                                } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack(alignment: .firstTextBaseline) {
                                            Text(program.timeLabel)
                                                .font(.subheadline.monospacedDigit().weight(.semibold))
                                            if isOnAir {
                                                Text("放送中")
                                                    .font(.subheadline.bold())
                                                    .foregroundStyle(DS.Palette.live)
                                            }
                                            if let kind = GuideAvailabilityPresentation
                                                .badgeKind(isOnAir: isOnAir, availability: availability)
                                            {
                                                MediaBadge(kind)
                                            }
                                        }
                                        Text(program.seriesTitle)
                                            .font(.headline)
                                        if program.title != program.seriesTitle {
                                            Text(program.title)
                                                .font(.body)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .foregroundStyle(.primary)
                                    .padding(14)
                                    .frame(maxWidth: .infinity, minHeight: ProgramGuideMetrics.minimumTapTarget, alignment: .leading)
                                    .background(Color(uiColor: .secondarySystemGroupedBackground))
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                }
                                .buttonStyle(.plain)
                                .disabled(hasNothingToPlay)
                                .opacity(hasNothingToPlay ? 0.45 : 1)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(
                                    GuideAvailabilityPresentation.accessibilityLabel(
                                        base: TVerAccessibilityText.guideProgram(
                                            stationName: item.channel.name,
                                            program: program,
                                            isOnAir: isOnAir
                                        ),
                                        isOnAir: isOnAir,
                                        availability: availability
                                    )
                                )
                                .accessibilityHint(
                                    GuideAvailabilityPresentation.accessibilityHint(
                                        isOnAir: isOnAir,
                                        availability: availability
                                    )
                                )
                                .accessibilityAddTraits(isOnAir ? .isSelected : [])
                                .accessibilityRemoveTraits(hasNothingToPlay ? .isButton : [])
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .accessibilityElement(children: .contain)
    }
}

struct ProgramGuideSelection: Identifiable {
    let channel: TVerLiveChannel
    let program: TVerLiveProgram

    var id: String {
        "\(channel.id)-\(program.id)-\(program.startAt.timeIntervalSince1970)"
    }
}

private struct ProgramGuideDetailSheet: View {
    let selection: ProgramGuideSelection
    @ObservedObject var playbackController: PlaybackController
    @ObservedObject var libraryStore: ProgramLibraryStore
    let notificationScheduler: ProgramNotificationScheduler
    let catchUpLookup: GuideCatchUpLookup
    @StateObject private var pictureInPicture = PictureInPictureCoordinator()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var requestedPlayback = false
    @State private var catchUpState: GuideCatchUpState = .idle
    @State private var catchUpPlayback: TVerProgram?
    @State private var selectedLeadTime: ProgramNotificationLeadTime
    @State private var isNotificationScheduled = false
    @State private var isUpdatingNotification = false
    @State private var notificationStatus: String?
    @State private var notificationStatusIsError = false

    init(
        selection: ProgramGuideSelection,
        playbackController: PlaybackController,
        libraryStore: ProgramLibraryStore,
        notificationScheduler: ProgramNotificationScheduler,
        catchUpLookup: GuideCatchUpLookup
    ) {
        self.selection = selection
        self.playbackController = playbackController
        self.libraryStore = libraryStore
        self.notificationScheduler = notificationScheduler
        self.catchUpLookup = catchUpLookup
        let preferredLeadTime: ProgramNotificationLeadTime = selection.program.startAt
            .addingTimeInterval(-ProgramNotificationLeadTime.fiveMinutes.rawValue) > Date()
            ? .fiveMinutes : .atStart
        _selectedLeadTime = State(initialValue: preferredLeadTime)
    }

    private var route: GuidePlaybackRoute {
        GuidePlaybackRouter.route(for: selection.program, channelState: selection.channel.state)
    }

    private var canPlay: Bool { route == .live }

    private var playbackChannel: TVerLiveChannel {
        TVerLiveChannel(
            id: selection.channel.id,
            name: selection.channel.name,
            iconURL: selection.channel.iconURL,
            projectID: selection.channel.projectID,
            mediaID: selection.channel.mediaID,
            apiKey: selection.channel.apiKey,
            currentProgram: selection.program,
            state: canPlay ? .onAir : selection.channel.state
        )
    }

    private var shareItem: ProgramShareItem { ProgramShareItem(channel: playbackChannel) }
    private var isCurrent: Bool { playbackController.currentLiveChannel?.id == selection.channel.id }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if requestedPlayback {
                        PlaybackVideoSurface(
                            player: playbackController.player,
                            pictureInPicture: pictureInPicture,
                            accessibilityLabel: "\(selection.program.seriesTitle)のライブ動画プレイヤー",
                            cornerRadius: 10
                        )
                    } else {
                        CachedProgramImage(
                            url: selection.program.thumbnailURL ?? selection.channel.iconURL,
                            contentMode: .fill
                        ) {
                            ZStack {
                                Color(uiColor: .secondarySystemBackground)
                                Image(systemName: "tv").font(.largeTitle).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .clipped()
                        .accessibilityHidden(true)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(selection.channel.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(selection.program.seriesTitle).font(.title2.bold())
                        if selection.program.title != selection.program.seriesTitle {
                            Text(selection.program.title).font(.headline).foregroundStyle(.secondary)
                        }
                        Label(selection.program.timeLabel, systemImage: "clock")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Text(selection.program.description.isEmpty ? "この番組の詳しい説明はありません。" : selection.program.description)
                            .font(.body)
                            .foregroundStyle(selection.program.description.isEmpty ? .secondary : .primary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        TVerAccessibilityText.guideProgram(
                            stationName: selection.channel.name,
                            program: selection.program,
                            isOnAir: canPlay
                        )
                    )

                    if isFutureProgram {
                        notificationControls
                    }

                    if requestedPlayback, isCurrent, let presentation = playbackController.errorPresentation {
                        PlaybackFailureView(presentation: presentation, officialURL: selection.channel.webURL) {
                            Task { await playbackController.playLive(playbackChannel) }
                        }
                    } else {
                        Button {
                            handlePlayAction()
                        } label: {
                            if playButtonState.isSearching {
                                HStack(spacing: 8) {
                                    ProgressView()
                                    Text(GuidePlaybackButtonState.catchUpSearchingTitle)
                                }
                                .frame(maxWidth: .infinity, minHeight: 44)
                            } else {
                                Label(playButtonState.title, systemImage: playButtonState.systemImage)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(!playButtonState.isEnabled)
                        .accessibilityIdentifier(GuideAccessibilityIdentifier.playButton)
                        .accessibilityLabel(playButtonState.title)
                        .accessibilityHint(playButtonHint)
                    }

                    if let catchUpMessage {
                        VStack(alignment: .leading, spacing: 12) {
                            Label(catchUpMessage, systemImage: "exclamationmark.magnifyingglass")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier(GuideAccessibilityIdentifier.catchUpNotFound)

                            Button { openURL(selection.channel.webURL) } label: {
                                Label("TVer公式ページで開く", systemImage: "safari")
                                    .frame(maxWidth: .infinity, minHeight: ProgramGuideMetrics.minimumTapTarget)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(uiColor: .secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .accessibilityElement(children: .contain)
                    }

                    if requestedPlayback {
                        PictureInPictureControl(coordinator: pictureInPicture)
                    }

                    ShareLink(item: shareItem.url, subject: Text(shareItem.subject), message: Text(shareItem.message)) {
                        Label("番組を共有", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    if !(requestedPlayback && isCurrent && playbackController.errorPresentation != nil) {
                        Button { openURL(selection.channel.webURL) } label: {
                            Label("TVer公式ライブページで開く", systemImage: "safari")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                }
                .padding(20)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("番組詳細")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { dismiss() }
                        .frame(
                            minWidth: ProgramGuideMetrics.minimumTapTarget,
                            minHeight: ProgramGuideMetrics.minimumTapTarget
                        )
                }
            }
        }
        .sheet(item: $catchUpPlayback) { program in
            PlaybackView(
                program: program,
                playbackController: playbackController,
                libraryStore: libraryStore
            )
        }
    }

    private var isFutureProgram: Bool {
        !selection.program.isPause && selection.program.startAt > Date()
    }

    private var availableLeadTimes: [ProgramNotificationLeadTime] {
        [
            .thirtyMinutes,
            .tenMinutes,
            .fiveMinutes,
            .atStart,
        ].filter { selection.program.startAt.addingTimeInterval(-$0.rawValue) > Date() }
    }

    private var notificationControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("放送開始通知", systemImage: "bell")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            Menu {
                ForEach(availableLeadTimes, id: \.rawValue) { leadTime in
                    Button {
                        selectedLeadTime = leadTime
                    } label: {
                        if leadTime == selectedLeadTime {
                            Label(notificationLeadTimeLabel(leadTime), systemImage: "checkmark")
                        } else {
                            Text(notificationLeadTimeLabel(leadTime))
                        }
                    }
                }
            } label: {
                HStack {
                    Text("通知時刻")
                    Spacer()
                    Text(notificationLeadTimeLabel(selectedLeadTime))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                }
                .frame(maxWidth: .infinity, minHeight: ProgramGuideMetrics.minimumTapTarget)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("通知時刻、\(notificationLeadTimeLabel(selectedLeadTime))")
            .accessibilityHint("ダブルタップして通知時刻を選びます")

            Button {
                scheduleNotification()
            } label: {
                Label(
                    isNotificationScheduled ? "通知を更新" : "通知を設定",
                    systemImage: isNotificationScheduled ? "bell.badge.fill" : "bell.badge"
                )
                .frame(maxWidth: .infinity, minHeight: ProgramGuideMetrics.minimumTapTarget)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isUpdatingNotification || availableLeadTimes.isEmpty)
            .accessibilityHint("選択した時刻に、この番組の放送開始を通知します")

            if isNotificationScheduled {
                Button(role: .destructive) {
                    cancelNotification()
                } label: {
                    Label("通知を解除", systemImage: "bell.slash")
                        .frame(maxWidth: .infinity, minHeight: ProgramGuideMetrics.minimumTapTarget)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(isUpdatingNotification)
            }

            if isUpdatingNotification {
                ProgressView("通知を更新中")
            }

            if let notificationStatus {
                Text(notificationStatus)
                    .font(.footnote)
                    .foregroundStyle(notificationStatusIsError ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private func notificationLeadTimeLabel(_ leadTime: ProgramNotificationLeadTime) -> String {
        switch leadTime {
        case .thirtyMinutes:
            return "30分前"
        case .tenMinutes:
            return "10分前"
        case .fiveMinutes:
            return "5分前"
        default:
            return "開始時刻"
        }
    }

    private func scheduleNotification() {
        isUpdatingNotification = true
        notificationStatus = nil
        Task {
            do {
                var authorization = await notificationScheduler.authorizationState()
                if authorization == .notDetermined {
                    authorization = try await notificationScheduler.requestAuthorization()
                }
                guard authorization.canSchedule else {
                    throw ProgramNotificationSchedulerError.authorizationDenied
                }
                _ = try await notificationScheduler.update(
                    program: selection.program,
                    channel: selection.channel,
                    leadTime: selectedLeadTime
                )
                isNotificationScheduled = true
                notificationStatusIsError = false
                notificationStatus = "\(notificationLeadTimeLabel(selectedLeadTime))に通知します。"
            } catch {
                notificationStatusIsError = true
                notificationStatus = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            isUpdatingNotification = false
            UIAccessibility.post(notification: .announcement, argument: notificationStatus)
        }
    }

    private func cancelNotification() {
        isUpdatingNotification = true
        notificationStatus = nil
        Task {
            await notificationScheduler.cancel(program: selection.program, channel: selection.channel)
            isNotificationScheduled = false
            notificationStatusIsError = false
            notificationStatus = "通知を解除しました。"
            isUpdatingNotification = false
            UIAccessibility.post(notification: .announcement, argument: notificationStatus)
        }
    }

    private var playButtonState: GuidePlaybackButtonState {
        GuidePlaybackButtonState.make(
            route: route,
            program: selection.program,
            catchUpState: catchUpState,
            isLivePlaybackRequested: requestedPlayback,
            isLiveResolving: playbackController.state == .resolving,
            isLivePlaying: playbackController.isPlaying,
            hasLivePlayerItem: playbackController.player.currentItem != nil
        )
    }

    private var playButtonHint: String {
        switch route {
        case .live:
            return "現在放送中の番組を再生します"
        case .catchUp:
            return "この放送回の見逃し配信を探して再生します"
        case .unavailable:
            return selection.program.isPause ? "配信休止中のため再生できません" : "放送開始後に再生できます"
        }
    }

    private var catchUpMessage: String? {
        guard route == .catchUp else { return nil }
        switch catchUpState {
        case .notFound:
            return GuideCatchUpLookup.notFoundMessage
        case let .failed(message):
            return message
        default:
            return nil
        }
    }

    private func handlePlayAction() {
        switch route {
        case .live:
            if requestedPlayback, playbackController.player.currentItem != nil {
                playbackController.togglePlayback()
            } else {
                DiagnosticLogStore.shared.record(
                    .info,
                    category: "playback",
                    message: "Guide live playback selected"
                )
                requestedPlayback = true
                Task { await playbackController.playLive(playbackChannel) }
            }
        case .catchUp:
            startCatchUpPlayback()
        case .unavailable:
            break
        }
    }

    private func startCatchUpPlayback() {
        if case let .found(episode) = catchUpState {
            catchUpPlayback = episode
            return
        }
        guard catchUpState != .searching else { return }
        DiagnosticLogStore.shared.record(
            .info,
            category: "playback",
            message: "Guide catch-up playback selected",
            metadata: ["channel": selection.channel.id, "slot": selection.program.id]
        )
        catchUpState = .searching
        Task {
            let result = await catchUpLookup.resolve(
                channelID: selection.channel.id,
                program: selection.program
            )
            catchUpState = result
            switch result {
            case let .found(episode):
                catchUpPlayback = episode
            case .notFound:
                UIAccessibility.post(notification: .announcement, argument: GuideCatchUpLookup.notFoundMessage)
            case let .failed(message):
                UIAccessibility.post(notification: .announcement, argument: message)
            default:
                break
            }
        }
    }
}

enum GuideAccessibilityIdentifier {
    static let playButton = "guide.play.button"
    static let catchUpNotFound = "guide.catchup.notfound"
    static let catchUpBadge = "guide.catchup.badge"
    static let offlineBanner = "guide.offline.banner"
}

/// Outcome of looking up the catch-up (見逃し配信) episode for a finished broadcast slot.
enum GuideCatchUpState: Equatable, Sendable {
    case idle
    case searching
    case found(TVerProgram)
    case notFound
    case failed(String)
}

/// Testable wrapper that turns `TVerCatchUpLookupServicing` results into `GuideCatchUpState`.
struct GuideCatchUpLookup: Sendable {
    static let notFoundMessage = "この放送の見逃し配信は見つかりませんでした"

    let service: any TVerCatchUpLookupServicing

    init(service: any TVerCatchUpLookupServicing = TVerAPIClient()) {
        self.service = service
    }

    func resolve(channelID: String, program: TVerLiveProgram) async -> GuideCatchUpState {
        do {
            if let episode = try await service.findCatchUpProgram(channelID: channelID, program: program) {
                return .found(episode)
            }
            return .notFound
        } catch {
            return .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
}

/// Presentation of the program-guide detail sheet primary playback button.
struct GuidePlaybackButtonState: Equatable, Sendable {
    static let catchUpTitle = "見逃し配信を再生"
    static let catchUpSearchingTitle = "見逃し配信を検索中"
    static let catchUpSystemImage = "play.rectangle.on.rectangle"

    let title: String
    let systemImage: String
    let isEnabled: Bool
    let isSearching: Bool

    static func make(
        route: GuidePlaybackRoute,
        program: TVerLiveProgram,
        catchUpState: GuideCatchUpState,
        isLivePlaybackRequested: Bool = false,
        isLiveResolving: Bool = false,
        isLivePlaying: Bool = false,
        hasLivePlayerItem: Bool = false,
        now: Date = Date()
    ) -> GuidePlaybackButtonState {
        switch route {
        case .live:
            if isLivePlaybackRequested, isLiveResolving {
                return GuidePlaybackButtonState(
                    title: "再生を準備中",
                    systemImage: "play.fill",
                    isEnabled: false,
                    isSearching: false
                )
            }
            if isLivePlaybackRequested, hasLivePlayerItem {
                return GuidePlaybackButtonState(
                    title: isLivePlaying ? "一時停止" : "再生",
                    systemImage: isLivePlaying ? "pause.fill" : "play.fill",
                    isEnabled: true,
                    isSearching: false
                )
            }
            return GuidePlaybackButtonState(
                title: "ライブを再生",
                systemImage: "play.fill",
                isEnabled: true,
                isSearching: false
            )
        case .catchUp:
            if catchUpState == .searching {
                return GuidePlaybackButtonState(
                    title: catchUpSearchingTitle,
                    systemImage: catchUpSystemImage,
                    isEnabled: false,
                    isSearching: true
                )
            }
            return GuidePlaybackButtonState(
                title: catchUpTitle,
                systemImage: catchUpSystemImage,
                isEnabled: true,
                isSearching: false
            )
        case .unavailable:
            let isUpcoming = !program.isPause && program.startAt > now
            return GuidePlaybackButtonState(
                title: isUpcoming ? "放送前" : "配信休止",
                systemImage: isUpcoming ? "clock" : "pause.circle",
                isEnabled: false,
                isSearching: false
            )
        }
    }
}

/// Badge shown on program-guide slots whose broadcast already finished.
struct GuideCatchUpBadge: View {
    var body: some View {
        Text("見逃し")
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(Color.accentColor)
            .background(Color.accentColor.opacity(0.16), in: Capsule())
            .accessibilityIdentifier(GuideAccessibilityIdentifier.catchUpBadge)
    }
}

private struct ProgramGuideStatusView<Accessory: View>: View {
    let title: String
    let message: String
    let systemImage: String
    @ViewBuilder let accessory: Accessory

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 42))
                .foregroundStyle(.blue)
                .accessibilityHidden(true)
            Text(title).font(.title3.bold()).multilineTextAlignment(.center)
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
            accessory
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Wording for the "this is not live data" banner.
enum ProgramGuideOfflineNotice {
    static let prefix = "オフライン表示中・最終更新 "
    static let unknownTimestamp = "不明"

    static func text(
        lastUpdatedAt: Date?,
        now: Date = Date(),
        calendar: Calendar = ProgramGuideMetrics.calendar
    ) -> String {
        guard let lastUpdatedAt else { return prefix + unknownTimestamp }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.timeZone = calendar.timeZone
        // A bare clock time would be misleading once the copy is a day old.
        formatter.dateFormat = calendar.isDate(lastUpdatedAt, inSameDayAs: now) ? "HH:mm" : "M/d HH:mm"
        return prefix + formatter.string(from: lastUpdatedAt)
    }
}

private struct ProgramGuideOfflineBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
                .foregroundStyle(.orange)
            Text(message)
                .font(.footnote)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.18))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
        .accessibilityIdentifier(GuideAccessibilityIdentifier.offlineBanner)
    }
}

/// Disk copy of the last successfully fetched programme guide.
struct ProgramGuideSnapshot: Codable, Sendable, Equatable {
    let savedAt: Date
    let guide: [TVerGuideChannel]

    private enum CodingKeys: String, CodingKey {
        case savedAt
        case guide
    }

    init(savedAt: Date, guide: [TVerGuideChannel]) {
        self.savedAt = savedAt
        self.guide = guide.map(ProgramGuideSnapshot.redacted)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        savedAt = try container.decode(Date.self, forKey: .savedAt)
        // Re-redact on the way in as well, so a file written by an older build
        // can never hand credentials back to the app.
        guide = try container.decode([TVerGuideChannel].self, forKey: .guide)
            .map(ProgramGuideSnapshot.redacted)
    }

    /// Strips the playback credentials from a channel.
    ///
    /// `apiKey`, `projectID` and `mediaID` authorise streaming; they must never
    /// be written to the Caches directory. They are also useless offline, and a
    /// successful fetch always supplies fresh ones.
    static func redacted(_ channel: TVerGuideChannel) -> TVerGuideChannel {
        let source = channel.channel
        return TVerGuideChannel(
            channel: TVerLiveChannel(
                id: source.id,
                name: source.name,
                iconURL: source.iconURL,
                projectID: "",
                mediaID: "",
                apiKey: "",
                currentProgram: source.currentProgram,
                state: source.state
            ),
            programs: channel.programs
        )
    }
}

/// Persists the programme guide so a cold launch without connectivity still
/// shows something. A nil directory means "memory only", which is what unit
/// tests and previews get unless they pass an explicit location.
actor ProgramGuideSnapshotStore {
    static let defaultMaximumAge: TimeInterval = 3 * 24 * 60 * 60
    static let defaultMaximumChannelCount = 64

    static let shared: ProgramGuideSnapshotStore? = {
        guard let directory = TVerOfflineCache.directory(named: "TVerProgramGuide") else { return nil }
        return ProgramGuideSnapshotStore(directory: directory)
    }()

    private let directory: URL
    private let fileURL: URL
    private let maximumAge: TimeInterval
    private let maximumChannelCount: Int
    private let fileManager: FileManager
    private var failureDescription: String?

    init(
        directory: URL,
        name: String = "program-guide",
        maximumAge: TimeInterval = ProgramGuideSnapshotStore.defaultMaximumAge,
        maximumChannelCount: Int = ProgramGuideSnapshotStore.defaultMaximumChannelCount,
        fileManager: FileManager = .default
    ) {
        self.directory = directory
        fileURL = directory.appendingPathComponent("\(name).json", isDirectory: false)
        self.maximumAge = max(0, maximumAge)
        self.maximumChannelCount = max(0, maximumChannelCount)
        self.fileManager = fileManager
    }

    func save(_ guide: [TVerGuideChannel], at date: Date) {
        let snapshot = ProgramGuideSnapshot(
            savedAt: date,
            guide: Array(guide.prefix(maximumChannelCount))
        )
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
            failureDescription = nil
        } catch {
            failureDescription = String(describing: type(of: error))
        }
    }

    func load(at date: Date) -> ProgramGuideSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(ProgramGuideSnapshot.self, from: data) else {
            // Truncated or foreign payload: drop it so the next save is clean.
            try? fileManager.removeItem(at: fileURL)
            return nil
        }
        // A snapshot from the future means the clock moved; treat it as stale
        // rather than trusting it indefinitely.
        guard
            snapshot.savedAt <= date.addingTimeInterval(3_600),
            date.timeIntervalSince(snapshot.savedAt) <= maximumAge
        else {
            try? fileManager.removeItem(at: fileURL)
            return nil
        }
        return snapshot
    }

    func lastFailure() -> String? {
        failureDescription
    }

    func clear() {
        try? fileManager.removeItem(at: fileURL)
        failureDescription = nil
    }
}
