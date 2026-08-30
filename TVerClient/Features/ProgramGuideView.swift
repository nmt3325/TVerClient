import AVKit
import SwiftUI
import UIKit

@MainActor
final class ProgramGuideViewModel: ObservableObject {
    @Published private(set) var guide: [TVerGuideChannel] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let service: any TVerProgramGuideServicing
    private let usesPreviewFallback: Bool
    private var hasLoaded = false

    init(service: any TVerProgramGuideServicing, usesPreviewFallback: Bool = true) {
        self.service = service
        self.usesPreviewFallback = usesPreviewFallback
    }

    var showsInitialLoading: Bool {
        isLoading && guide.isEmpty
    }

    var hasPrograms: Bool {
        guide.contains { !$0.programs.isEmpty }
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
            let response = try await service.fetchProgramGuide(forceRefresh: hasLoaded)
            #if DEBUG
                guide = response.contains(where: { !$0.programs.isEmpty }) || !usesPreviewFallback
                    ? response : PreviewFixture.programGuide
            #else
                guide = response
            #endif
            hasLoaded = true
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
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

enum ProgramGuideMetrics {
    static let stationWidth: CGFloat = 168
    static let hourHeight: CGFloat = 112
    static let timeAxisWidth: CGFloat = 58
    static let stationHeaderHeight: CGFloat = 66
    static let minimumTapTarget: CGFloat = 44
    static let minimumProgramHeight = minimumTapTarget

    static func gridSize(channelCount: Int) -> CGSize {
        CGSize(
            width: CGFloat(max(0, channelCount)) * stationWidth,
            height: 24 * hourHeight
        )
    }

    static func xPosition(forColumn column: Int) -> CGFloat {
        CGFloat(max(0, column)) * stationWidth
    }

    static func hourLabel(_ hour: Int) -> String {
        String(format: "%02d:00", min(max(0, hour), 23))
    }

    static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.locale = Locale(identifier: "ja_JP")
        value.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current
        return value
    }

    static func dayInterval(for date: Date) -> DateInterval {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
        return DateInterval(start: start, end: end)
    }

    static func dates(in guide: [TVerGuideChannel]) -> [Date] {
        let values = guide.flatMap(\.programs).map { calendar.startOfDay(for: $0.startAt) }
        return Array(Set(values)).sorted()
    }

    static func programs(_ programs: [TVerLiveProgram], on date: Date) -> [TVerLiveProgram] {
        let day = dayInterval(for: date)
        return programs.filter { $0.startAt < day.end && $0.endAt > day.start }
    }

    static func yPosition(for date: Date, on selectedDate: Date) -> CGFloat {
        let day = dayInterval(for: selectedDate)
        let clipped = min(max(date, day.start), day.end)
        return CGFloat(clipped.timeIntervalSince(day.start) / 3600) * hourHeight
    }

    static func height(for program: TVerLiveProgram, on selectedDate: Date) -> CGFloat {
        let day = dayInterval(for: selectedDate)
        let start = max(program.startAt, day.start)
        let end = min(program.endAt, day.end)
        return max(minimumProgramHeight, CGFloat(max(0, end.timeIntervalSince(start)) / 3600) * hourHeight)
    }

    static func isSameDay(_ lhs: Date, _ rhs: Date) -> Bool {
        calendar.isDate(lhs, inSameDayAs: rhs)
    }
}

struct ProgramGuideView: View {
    @StateObject private var viewModel: ProgramGuideViewModel
    @ObservedObject private var playbackController: PlaybackController
    @ObservedObject private var libraryStore: ProgramLibraryStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedDate = ProgramGuideMetrics.calendar.startOfDay(for: Date())
    @State private var selectedProgram: ProgramGuideSelection?
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
               let nearest = dates.min(by: { abs($0.timeIntervalSinceNow) < abs($1.timeIntervalSinceNow) })
            {
                selectedDate = nearest
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
            ProgramGuideDatePicker(
                dates: ProgramGuideMetrics.dates(in: viewModel.guide),
                selectedDate: $selectedDate
            )
            Divider()
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    ProgramGuideAccessibleList(
                        guide: viewModel.guide,
                        selectedDate: selectedDate,
                        onSelect: selectProgram
                    )
                } else {
                    ProgramGuideGrid(
                        guide: viewModel.guide,
                        selectedDate: selectedDate,
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

                            ForEach(programs) { program in
                                let now = Date()
                                let isOnAir = program.startAt <= now && now < program.endAt
                                let isCatchUpAvailable = GuidePlaybackRouter.route(
                                    for: program,
                                    channelState: item.channel.state,
                                    now: now
                                ) == .catchUp
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
                                                    .foregroundStyle(.red)
                                            }
                                            if isCatchUpAvailable {
                                                GuideCatchUpBadge()
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
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(
                                    TVerAccessibilityText.guideProgram(
                                        stationName: item.channel.name,
                                        program: program,
                                        isOnAir: isOnAir
                                    )
                                )
                                .accessibilityHint(
                                    isCatchUpAvailable
                                        ? "ダブルタップして番組詳細を開き、見逃し配信を再生できます"
                                        : "ダブルタップして番組詳細を開きます"
                                )
                                .accessibilityAddTraits(isOnAir ? .isSelected : [])
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

private struct ProgramGuideGrid: View {
    let guide: [TVerGuideChannel]
    let selectedDate: Date
    let onSelect: (TVerLiveChannel, TVerLiveProgram) -> Void
    @State private var contentOffset = CGPoint.zero

    private var contentSize: CGSize {
        ProgramGuideMetrics.gridSize(channelCount: guide.count)
    }

    var body: some View {
        GeometryReader { proxy in
            let bodyHeight = max(0, proxy.size.height - ProgramGuideMetrics.stationHeaderHeight)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text("時刻")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: ProgramGuideMetrics.timeAxisWidth, height: ProgramGuideMetrics.stationHeaderHeight)
                        .background(.regularMaterial)
                        .accessibilityAddTraits(.isHeader)
                    stationHeaders
                        .frame(height: ProgramGuideMetrics.stationHeaderHeight)
                }
                Divider()
                HStack(spacing: 0) {
                    timeScale
                        .frame(width: ProgramGuideMetrics.timeAxisWidth, height: bodyHeight, alignment: .top)
                        .clipped()
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        SynchronizedGuideScrollView(
                            contentOffset: $contentOffset,
                            contentSize: contentSize
                        ) {
                            ProgramGuideCanvas(
                                guide: guide,
                                selectedDate: selectedDate,
                                now: context.date,
                                onSelect: onSelect
                            )
                            .frame(width: contentSize.width, height: contentSize.height)
                        }
                    }
                }
            }
            .onAppear {
                let now = Date()
                let targetDate = ProgramGuideMetrics.isSameDay(now, selectedDate)
                    ? now : ProgramGuideMetrics.calendar.date(bySettingHour: 6, minute: 0, second: 0, of: selectedDate) ?? selectedDate
                contentOffset.y = max(0, ProgramGuideMetrics.yPosition(for: targetDate, on: selectedDate) - 120)
            }
        }
    }

    private var stationHeaders: some View {
        GeometryReader { _ in
            HStack(spacing: 0) {
                ForEach(guide) { item in
                    HStack(spacing: 8) {
                        CachedProgramImage(url: item.channel.iconURL, contentMode: .fit) {
                            Image(systemName: "tv").foregroundStyle(.secondary)
                        }
                        .frame(width: 28, height: 28)
                        .accessibilityHidden(true)
                        Text(item.channel.name)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                    }
                    .padding(.horizontal, 10)
                    .frame(width: ProgramGuideMetrics.stationWidth, height: ProgramGuideMetrics.stationHeaderHeight)
                    .background(.regularMaterial)
                    .overlay(alignment: .trailing) { Divider() }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(item.channel.name)、放送局")
                    .accessibilityAddTraits(.isHeader)
                }
            }
            .offset(x: -contentOffset.x)
            .frame(width: contentSize.width, alignment: .leading)
        }
        .clipped()
    }

    private var timeScale: some View {
        ZStack(alignment: .topLeading) {
            Color(uiColor: .systemGroupedBackground)
            ForEach(0 ..< 24, id: \.self) { hour in
                Text(ProgramGuideMetrics.hourLabel(hour))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: ProgramGuideMetrics.timeAxisWidth - 8, alignment: .trailing)
                    .offset(y: CGFloat(hour) * ProgramGuideMetrics.hourHeight - 7)
            }
        }
        .frame(height: contentSize.height, alignment: .top)
        .offset(y: -contentOffset.y)
        .background(Color(uiColor: .systemGroupedBackground))
        .accessibilityHidden(true)
    }
}

private struct ProgramGuideCanvas: View {
    let guide: [TVerGuideChannel]
    let selectedDate: Date
    let now: Date
    let onSelect: (TVerLiveChannel, TVerLiveProgram) -> Void

    private var width: CGFloat {
        CGFloat(guide.count) * ProgramGuideMetrics.stationWidth
    }

    private var height: CGFloat {
        24 * ProgramGuideMetrics.hourHeight
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(uiColor: .systemBackground)
            columnBackgrounds
            gridLines
            programs
            currentTimeLine
        }
        .frame(width: width, height: height)
    }

    private var columnBackgrounds: some View {
        HStack(spacing: 0) {
            ForEach(Array(guide.enumerated()), id: \.element.id) { index, _ in
                (index.isMultiple(of: 2)
                    ? Color(uiColor: .systemBackground)
                    : Color(uiColor: .secondarySystemBackground).opacity(0.45))
                    .frame(width: ProgramGuideMetrics.stationWidth, height: height)
            }
        }
    }

    private var gridLines: some View {
        ZStack(alignment: .topLeading) {
            ForEach(0 ... 48, id: \.self) { halfHour in
                Rectangle()
                    .fill(Color(uiColor: .separator).opacity(halfHour.isMultiple(of: 2) ? 0.42 : 0.18))
                    .frame(width: width, height: halfHour.isMultiple(of: 2) ? 1 : 0.5)
                    .offset(y: CGFloat(halfHour) * ProgramGuideMetrics.hourHeight / 2)
            }
            ForEach(0 ... guide.count, id: \.self) { column in
                Rectangle()
                    .fill(Color(uiColor: .separator).opacity(0.35))
                    .frame(width: 1, height: height)
                    .offset(x: CGFloat(column) * ProgramGuideMetrics.stationWidth)
            }
        }
        .accessibilityHidden(true)
    }

    private var programs: some View {
        ForEach(Array(guide.enumerated()), id: \.element.id) { column, item in
            ForEach(ProgramGuideMetrics.programs(item.programs, on: selectedDate)) { program in
                let y = ProgramGuideMetrics.yPosition(for: program.startAt, on: selectedDate)
                let programHeight = ProgramGuideMetrics.height(for: program, on: selectedDate)
                ProgramGuideBlock(
                    stationName: item.channel.name,
                    program: program,
                    isOnAir: program.startAt <= now && now < program.endAt,
                    isCatchUpAvailable: GuidePlaybackRouter.route(
                        for: program,
                        channelState: item.channel.state,
                        now: now
                    ) == .catchUp
                ) {
                    onSelect(item.channel, program)
                }
                .frame(width: ProgramGuideMetrics.stationWidth - 6, height: programHeight)
                .offset(
                    x: ProgramGuideMetrics.xPosition(forColumn: column) + 3,
                    y: y
                )
            }
        }
    }

    @ViewBuilder
    private var currentTimeLine: some View {
        if ProgramGuideMetrics.isSameDay(now, selectedDate) {
            let y = ProgramGuideMetrics.yPosition(for: now, on: selectedDate)
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.red).frame(width: width, height: 2)
                Circle().fill(Color.red).frame(width: 9, height: 9).offset(x: -4)
            }
            .offset(y: y)
            .accessibilityHidden(true)
        }
    }
}

private struct ProgramGuideBlock: View {
    let stationName: String
    let program: TVerLiveProgram
    let isOnAir: Bool
    let isCatchUpAvailable: Bool
    let action: () -> Void

    var body: some View {
        GeometryReader { proxy in
            Button(action: action) {
                VStack(alignment: .leading, spacing: proxy.size.height < 62 ? 1 : 3) {
                    HStack(spacing: 4) {
                        Text(program.timeLabel)
                            .font(.caption2.monospacedDigit().weight(.semibold))
                        if isOnAir {
                            Text("放送中")
                                .font(.caption2.bold())
                                .foregroundStyle(.red)
                        }
                        if isCatchUpAvailable {
                            GuideCatchUpBadge()
                        }
                    }
                    .lineLimit(1)
                    Text(program.seriesTitle)
                        .font(.footnote.weight(.semibold))
                        .lineLimit(proxy.size.height < 76 ? 1 : 2)
                    if proxy.size.height >= 76, program.title != program.seriesTitle {
                        Text(program.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(proxy.size.height >= 112 ? 2 : 1)
                    }
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(blockBackground)
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(isOnAir ? Color.accentColor : Color(uiColor: .separator).opacity(0.42), lineWidth: isOnAir ? 2 : 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(TVerAccessibilityText.guideProgram(
            stationName: stationName,
            program: program,
            isOnAir: isOnAir
        ))
        .accessibilityHint(
            isCatchUpAvailable
                ? "ダブルタップして番組詳細を開き、見逃し配信を再生できます"
                : "ダブルタップして番組詳細を開きます"
        )
        .accessibilityInputLabels([program.seriesTitle, program.title])
        .accessibilityAddTraits(isOnAir ? .isSelected : [])
    }

    private var blockBackground: Color {
        if program.isPause {
            return Color(uiColor: .tertiarySystemFill)
        }
        if isOnAir {
            return Color.accentColor.opacity(0.14)
        }
        return Color(uiColor: .secondarySystemBackground)
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

private struct SynchronizedGuideScrollView<Content: View>: UIViewRepresentable {
    @Binding var contentOffset: CGPoint
    let contentSize: CGSize
    @ViewBuilder let content: Content

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.backgroundColor = .clear
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.alwaysBounceHorizontal = contentSize.width > 0
        scrollView.alwaysBounceVertical = true
        scrollView.showsHorizontalScrollIndicator = true
        scrollView.showsVerticalScrollIndicator = true
        scrollView.isDirectionalLockEnabled = false

        let hostedView = context.coordinator.hostingController.view!
        hostedView.backgroundColor = .clear
        hostedView.frame = CGRect(origin: .zero, size: contentSize)
        scrollView.addSubview(hostedView)
        scrollView.contentSize = contentSize
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.hostingController.rootView = content
        context.coordinator.hostingController.view.frame = CGRect(origin: .zero, size: contentSize)
        scrollView.contentSize = contentSize
        if !scrollView.isDragging && !scrollView.isDecelerating,
           abs(scrollView.contentOffset.x - contentOffset.x) > 1 || abs(scrollView.contentOffset.y - contentOffset.y) > 1
        {
            scrollView.setContentOffset(contentOffset, animated: false)
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: SynchronizedGuideScrollView
        let hostingController: UIHostingController<Content>

        init(parent: SynchronizedGuideScrollView) {
            self.parent = parent
            hostingController = UIHostingController(rootView: parent.content)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard parent.contentOffset != scrollView.contentOffset else { return }
            parent.contentOffset = scrollView.contentOffset
        }
    }
}
