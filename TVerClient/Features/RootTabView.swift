import AVKit
import SwiftUI

struct RootTabView: View {
    @StateObject private var playbackController = PlaybackController()

    var body: some View {
        TabView {
            ScheduleView(
                viewModel: ScheduleViewModel(service: TVerAPIClient()),
                playbackController: playbackController
            )
            .tabItem {
                Label("番組表", systemImage: "rectangle.grid.1x2")
            }


            LiveView(
                viewModel: LiveViewModel(service: TVerAPIClient()),
                playbackController: playbackController
            )
            .tabItem {
                Label("ライブ", systemImage: "dot.radiowaves.left.and.right")
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

    var showsInitialLoading: Bool { isLoading && days.isEmpty }

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
        }

        isLoading = false
    }
}

private struct ScheduleView: View {
    @StateObject private var viewModel: ScheduleViewModel
    @ObservedObject private var playbackController: PlaybackController
    @State private var selectedProgram: TVerProgram?

    init(viewModel: ScheduleViewModel, playbackController: PlaybackController) {
        _viewModel = StateObject(wrappedValue: viewModel)
        self.playbackController = playbackController
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
                            Task { await viewModel.load() }
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
                            Task { await viewModel.load() }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                } else {
                    scheduleList
                }
            }
            .navigationTitle("番組表")
            .background(Color(uiColor: .systemGroupedBackground))
        }
        .task { await viewModel.loadIfNeeded() }
        .sheet(item: $selectedProgram) { program in
            PlaybackView(program: program, playbackController: playbackController)
        }
    }

    private var scheduleList: some View {
        ScrollView {
            LazyVStack(spacing: 24, pinnedViews: [.sectionHeaders]) {
                ForEach(viewModel.days.filter { !$0.programs.isEmpty }) { day in
                    Section {
                        LazyVStack(spacing: 12) {
                            ForEach(day.programs) { program in
                                ProgramCard(program: program) {
                                    selectedProgram = program
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    } header: {
                        DayHeader(date: day.date)
                    }
                }
            }
            .padding(.bottom, 32)
        }
        .refreshable { await viewModel.load() }
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
                                LiveChannelCard(channel: channel) { selectedChannel = channel }
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

    var body: some View {
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
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(Color(uiColor: .separator).opacity(0.22)) }
        }
        .buttonStyle(CardButtonStyle())
        .disabled(!channel.isPlayable)
        .opacity(channel.isPlayable ? 1 : 0.72)
        .accessibilityLabel("\(channel.name)、\(channel.currentProgram?.seriesTitle ?? "番組情報なし")、\(channel.state.label)")
        .accessibilityHint(channel.isPlayable ? "ダブルタップしてライブを視聴します" : "現在は視聴できません")
    }
}

private struct LivePlaybackView: View {
    let channel: TVerLiveChannel
    @ObservedObject var playbackController: PlaybackController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VideoPlayer(player: playbackController.player)
                        .frame(maxWidth: .infinity).aspectRatio(16 / 9, contentMode: .fit)
                        .background(Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .accessibilityLabel("\(channel.name)のライブ動画プレイヤー")

                    VStack(alignment: .leading, spacing: 7) {
                        Label("配信中", systemImage: "dot.radiowaves.left.and.right")
                            .font(.caption.bold()).foregroundStyle(.red)
                        Text(channel.currentProgram?.seriesTitle ?? "TVer リアルタイム配信").font(.title2.bold())
                        Text(channel.currentProgram?.title ?? channel.name).foregroundStyle(.secondary)
                        if let program = channel.currentProgram {
                            Label(program.timeLabel, systemImage: "clock").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }

                    if playbackController.currentLiveChannel?.id == channel.id,
                       let message = playbackController.errorMessage {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("アプリ内で直接再生できません", systemImage: "exclamationmark.triangle")
                                .font(.headline)
                            Text(message).font(.subheadline).foregroundStyle(.secondary)
                            Text("下のボタンからTVer公式ライブページを開いてください。")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        .padding(14).background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    } else if playbackController.player.currentItem == nil {
                        HStack { Spacer(); ProgressView("公式配信URLを確認中"); Spacer() }
                    } else {
                        Button { playbackController.togglePlayback() } label: {
                            Label(playbackController.isPlaying ? "一時停止" : "再生", systemImage: playbackController.isPlaying ? "pause.fill" : "play.fill")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                    }

                    Button { openURL(channel.webURL) } label: {
                        Label("TVer公式ライブページで開く", systemImage: "safari")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered).controlSize(.large)
                }
                .padding(20)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(channel.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("閉じる") { dismiss() }.frame(minWidth: 44, minHeight: 44) } }
        }
        .task(id: channel.id) { await playbackController.playLive(channel) }
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
    let onWatch: () -> Void

    var body: some View {
        Button(action: onWatch) {
            ViewThatFits(in: .horizontal) {
                horizontalContent
                verticalContent
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color(uiColor: .separator).opacity(0.22), lineWidth: 1)
            }
        }
        .buttonStyle(CardButtonStyle())
        .accessibilityLabel("\(program.seriesTitle)、\(program.title)、\(program.broadcastLabel)")
        .accessibilityHint("ダブルタップして視聴画面を開きます")
    }

    private var horizontalContent: some View {
        HStack(alignment: .top, spacing: 16) {
            ProgramThumbnail(url: program.thumbnailURL)
                .frame(width: 152, height: 86)
            details
                .frame(maxWidth: .infinity, alignment: .leading)
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
            HStack(alignment: .center, spacing: 8) {
                Label(program.broadcastLabel, systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Label("視聴", systemImage: "play.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.blue)
                    .frame(minHeight: 44)
            }
        }
    }
}

private struct ProgramThumbnail: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeInOut)) { phase in
            switch phase {
            case .empty:
                ZStack {
                    thumbnailBackground
                    ProgressView()
                        .tint(.secondary)
                }
            case .success(let image):
                image
                    .resizable()
                    .scaledToFill()
            case .failure:
                ZStack {
                    thumbnailBackground
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("サムネイルを表示できません")
                }
            @unknown default:
                thumbnailBackground
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

private struct PlaybackView: View {
    let program: TVerProgram
    @ObservedObject var playbackController: PlaybackController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VideoPlayer(player: playbackController.player)
                        .frame(maxWidth: .infinity)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .background(Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .accessibilityLabel("\(program.seriesTitle)の動画プレイヤー")

                    VStack(alignment: .leading, spacing: 8) {
                        Text(program.seriesTitle)
                            .font(.title2.bold())
                        Text(program.title)
                            .font(.body)
                            .foregroundStyle(.secondary)
                        Label(program.broadcastLabel, systemImage: "clock")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    playbackControls

                    Button {
                        openURL(program.webURL)
                    } label: {
                        Label("TVer公式ページで開く", systemImage: "safari")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                .padding(20)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("視聴")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { dismiss() }
                        .frame(minWidth: 44, minHeight: 44)
                }
            }
        }
        .task(id: program.id) {
            await playbackController.play(program)
        }
    }

    private var playbackControls: some View {
        HStack(spacing: 20) {
            playbackButton(title: "15秒戻す", systemImage: "gobackward.15") {
                seek(by: -15)
            }

            Button {
                playbackController.togglePlayback()
            } label: {
                Image(systemName: playbackController.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .frame(width: 56, height: 56)
                    .background(Color.blue, in: Circle())
                    .foregroundStyle(.white)
            }
            .accessibilityLabel(playbackController.isPlaying ? "一時停止" : "再生")

            playbackButton(title: "15秒送る", systemImage: "goforward.15") {
                seek(by: 15)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func playbackButton(
        title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title2)
                .frame(width: 52, height: 52)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func seek(by seconds: Double) {
        let currentSeconds = playbackController.player.currentTime().seconds
        let safeCurrentSeconds = currentSeconds.isFinite ? currentSeconds : 0
        let target = CMTime(seconds: max(0, safeCurrentSeconds + seconds), preferredTimescale: 600)
        playbackController.player.seek(to: target)
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
