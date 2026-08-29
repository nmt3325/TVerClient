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
        }
        isLoading = false
    }
}

enum ProgramGuideMetrics {
    static let stationWidth: CGFloat = 168
    static let hourHeight: CGFloat = 112
    static let timeAxisWidth: CGFloat = 58
    static let stationHeaderHeight: CGFloat = 66
    static let minimumProgramHeight: CGFloat = 44

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
    @State private var selectedDate = ProgramGuideMetrics.calendar.startOfDay(for: Date())
    @State private var selectedProgram: ProgramGuideSelection?

    init(viewModel: ProgramGuideViewModel, playbackController: PlaybackController) {
        _viewModel = StateObject(wrappedValue: viewModel)
        self.playbackController = playbackController
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
                            .frame(minHeight: 44)
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
                            .frame(minHeight: 44)
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
                            ProgressView().frame(width: 44, height: 44)
                        } else {
                            Image(systemName: "arrow.clockwise").frame(width: 44, height: 44)
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
                playbackController: playbackController
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
            ProgramGuideGrid(
                guide: viewModel.guide,
                selectedDate: selectedDate,
                onSelect: { channel, program in
                    selectedProgram = ProgramGuideSelection(channel: channel, program: program)
                }
            )
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
}

private struct ProgramGuideDatePicker: View {
    let dates: [Date]
    @Binding var selectedDate: Date

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
                            .frame(minWidth: 68, minHeight: 44)
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
        return "\(formatter.string(from: date))、\(relativeLabel(for: date))"
    }
}

private struct ProgramGuideGrid: View {
    let guide: [TVerGuideChannel]
    let selectedDate: Date
    let onSelect: (TVerLiveChannel, TVerLiveProgram) -> Void
    @State private var contentOffset = CGPoint.zero

    private var contentSize: CGSize {
        CGSize(
            width: CGFloat(guide.count) * ProgramGuideMetrics.stationWidth,
            height: 24 * ProgramGuideMetrics.hourHeight
        )
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
                        AsyncImage(url: item.channel.iconURL) { phase in
                            if case let .success(image) = phase {
                                image.resizable().scaledToFit()
                            } else {
                                Image(systemName: "tv").foregroundStyle(.secondary)
                            }
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
                    .accessibilityElement(children: .combine)
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
                Text(String(format: "%02d:00", hour))
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
                    isOnAir: program.startAt <= now && now < program.endAt
                ) {
                    onSelect(item.channel, program)
                }
                .frame(width: ProgramGuideMetrics.stationWidth - 6, height: programHeight)
                .offset(
                    x: CGFloat(column) * ProgramGuideMetrics.stationWidth + 3,
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
        .accessibilityLabel(
            TVerAccessibilityText.guideProgram(
                stationName: stationName,
                program: program,
                isOnAir: isOnAir
            )
        )
        .accessibilityHint("ダブルタップして番組詳細を開きます")
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
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var requestedPlayback = false

    private var canPlay: Bool {
        let now = Date()
        return !selection.program.isPause
            && selection.program.startAt <= now
            && now < selection.program.endAt
    }

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
                        VideoPlayer(player: playbackController.player)
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .background(Color.black)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .accessibilityLabel("\(selection.program.seriesTitle)のライブ動画プレイヤー")
                    } else {
                        AsyncImage(url: selection.program.thumbnailURL ?? selection.channel.iconURL) { phase in
                            if case let .success(image) = phase {
                                image.resizable().scaledToFill()
                            } else {
                                ZStack {
                                    Color(uiColor: .secondarySystemBackground)
                                    Image(systemName: "tv").font(.largeTitle).foregroundStyle(.secondary)
                                }
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

                    if requestedPlayback, isCurrent, let presentation = playbackController.errorPresentation {
                        PlaybackFailureView(presentation: presentation, officialURL: selection.channel.webURL) {
                            Task { await playbackController.playLive(playbackChannel) }
                        }
                    } else {
                        Button {
                            if requestedPlayback, playbackController.player.currentItem != nil {
                                playbackController.togglePlayback()
                            } else {
                                requestedPlayback = true
                                Task { await playbackController.playLive(playbackChannel) }
                            }
                        } label: {
                            Label(playButtonTitle, systemImage: playButtonIcon)
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(!canPlay || (requestedPlayback && playbackController.state == .resolving))
                        .accessibilityHint(canPlay ? "現在放送中の番組を再生します" : "放送中のみ再生できます")
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
                    Button("閉じる") { dismiss() }.frame(minWidth: 44, minHeight: 44)
                }
            }
        }
    }

    private var playButtonTitle: String {
        guard canPlay else { return selection.program.startAt > Date() ? "放送開始後に再生" : "放送終了" }
        if requestedPlayback, playbackController.state == .resolving { return "再生を準備中" }
        if requestedPlayback, playbackController.player.currentItem != nil {
            return playbackController.isPlaying ? "一時停止" : "再生"
        }
        return "ライブを再生"
    }

    private var playButtonIcon: String {
        requestedPlayback && playbackController.isPlaying ? "pause.fill" : "play.fill"
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
