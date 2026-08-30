import AVKit
import SwiftUI

@MainActor
final class LiveViewModel: ObservableObject {
    @Published private(set) var channels: [TVerLiveChannel] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    /// 直近の取得で使ったエリア。エリアを切り替えたときだけ取り直すために持つ。
    @Published private(set) var loadedArea: TVerArea?

    private let service: any TVerLiveServicing
    /// エリア対応の実装を持っているサービスならこちらを使う。init のシグネチャは
    /// 契約で固定なので、ここでキャストして拾う。
    private let areaService: (any TVerAreaAwareServicing)?
    private let usesPreviewFallback: Bool
    private var hasLoaded = false
    private var currentArea: TVerArea?

    init(service: any TVerLiveServicing, usesPreviewFallback: Bool = true) {
        self.service = service
        areaService = service as? any TVerAreaAwareServicing
        self.usesPreviewFallback = usesPreviewFallback
    }

    /// エリア切替をサービス側が理解できるか。
    var supportsAreaSwitching: Bool { areaService != nil }

    /// 配信中（即座に見られる）チャンネル数。
    var playableChannelCount: Int { channels.filter(\.isPlayable).count }

    func loadIfNeeded() async {
        await loadIfNeeded(area: currentArea)
    }

    func loadIfNeeded(area: TVerArea?) async {
        guard !hasLoaded || loadedArea?.code != area?.code else { return }
        await load(area: area, forceRefresh: false)
    }

    func load() async {
        await load(area: currentArea, forceRefresh: false)
    }

    func load(area: TVerArea?) async {
        await load(area: area, forceRefresh: false)
    }

    /// 引き下げ更新。エリア別キャッシュを跨いで取り直す。
    func refresh() async {
        await load(area: currentArea, forceRefresh: true)
    }

    private func load(area: TVerArea?, forceRefresh: Bool) async {
        guard !isLoading else { return }
        currentArea = area
        isLoading = true
        errorMessage = nil
        do {
            let response: [TVerLiveChannel]
            if let areaService {
                response = try await areaService.fetchLiveChannels(area: area, forceRefresh: forceRefresh)
            } else {
                response = try await service.fetchLiveChannels(forceRefresh: forceRefresh)
            }
            #if DEBUG
                channels = response.isEmpty && usesPreviewFallback ? PreviewFixture.liveChannels : response
            #else
                channels = response
            #endif
            hasLoaded = true
            loadedArea = area
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

struct LiveView: View {
    @StateObject private var viewModel: LiveViewModel
    @ObservedObject private var playbackController: PlaybackController
    @EnvironmentObject private var areaStore: AreaStore
    @Environment(\.openURL) private var openURL
    @State private var selectedChannel: TVerLiveChannel?

    init(viewModel: LiveViewModel, playbackController: PlaybackController) {
        _viewModel = StateObject(wrappedValue: viewModel)
        self.playbackController = playbackController
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("ライブ")
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) { areaPicker }
                }
        }
        .task { await viewModel.loadIfNeeded(area: areaStore.selected) }
        .onChange(of: areaStore.selected) { newArea in
            Task { await viewModel.load(area: newArea) }
        }
        .sheet(item: $selectedChannel) { channel in
            LivePlaybackView(channel: channel, playbackController: playbackController)
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading, viewModel.channels.isEmpty {
            ContentStatusView(.loading("リアルタイム配信を読み込み中"))
        } else if let error = viewModel.errorMessage, viewModel.channels.isEmpty {
            ContentStatusView(.failure(title: "ライブを読み込めませんでした", message: error)) {
                Button("再試行") { Task { await viewModel.refresh() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        } else if viewModel.channels.isEmpty {
            ContentStatusView(
                .empty(
                    title: "配信中のチャンネルがありません",
                    message: "時間をおいて、もう一度更新してください。",
                    systemImage: "tv.slash"
                )
            ) {
                Button("更新") { Task { await viewModel.refresh() } }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            }
        } else {
            channelList
        }
    }

    private var channelList: some View {
        List {
            Section { availabilityNotice }
            Section {
                ForEach(viewModel.channels) { channel in
                    row(for: channel)
                }
            } header: {
                SectionHeader(
                    "チャンネル",
                    subtitle: "\(viewModel.playableChannelCount)/\(viewModel.channels.count) が今すぐ見られます"
                )
            }
        }
        .listStyle(.plain)
        .refreshable { await viewModel.refresh() }
        .overlay(alignment: .top) { refreshIndicator }
    }

    /// 再生を試す前に、このエリアで何が見られるのかを先に出す。
    private var availabilityNotice: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Label(TVerAreaAvailability.headline(for: areaStore.selected), systemImage: "info.circle")
                .font(.footnote.weight(.semibold))
            Text(TVerAreaAvailability.detail(for: areaStore.selected))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, DS.Spacing.xs)
        .listRowSeparator(.hidden)
        .accessibilityElement(children: .combine)
    }

    private func row(for channel: TVerLiveChannel) -> some View {
        Button {
            DiagnosticLogStore.shared.record(
                .info,
                category: "playback",
                message: "Live playback selected"
            )
            selectedChannel = channel
        } label: {
            MediaRow(
                title: channel.currentProgram?.seriesTitle ?? channel.name,
                subtitle: subtitle(for: channel),
                detail: detail(for: channel),
                thumbnailURL: channel.currentProgram?.thumbnailURL ?? channel.iconURL,
                badges: badges(for: channel)
            ) {
                Image(systemName: channel.isPlayable ? "play.circle.fill" : "nosign")
                    .font(.title3)
                    .foregroundStyle(channel.isPlayable ? DS.Palette.live : Color.secondary)
                    .frame(width: DS.Size.minimumTapTarget, height: DS.Size.minimumTapTarget)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.plain)
        .disabled(!channel.isPlayable)
        .opacity(channel.isPlayable ? 1 : 0.45)
        .listRowInsets(EdgeInsets(top: 0, leading: DS.Spacing.l, bottom: 0, trailing: DS.Spacing.l))
        .accessibilityLabel(TVerAccessibilityText.live(channel: channel))
        .accessibilityHint(channel.isPlayable ? "ダブルタップしてライブを視聴します" : "現在は視聴できません")
        .contextMenu { rowMenu(for: channel) }
    }

    @ViewBuilder
    private func rowMenu(for channel: TVerLiveChannel) -> some View {
        let shareItem = ProgramShareItem(channel: channel)
        ShareLink(
            item: shareItem.url,
            subject: Text(shareItem.subject),
            message: Text(shareItem.message)
        ) {
            Label("共有", systemImage: "square.and.arrow.up")
        }
        Button {
            openURL(channel.webURL)
        } label: {
            Label("TVer公式ページで開く", systemImage: "safari")
        }
    }

    private var areaPicker: some View {
        Menu {
            Picker("エリア", selection: $areaStore.selected) {
                ForEach(areaStore.groupedAreas) { group in
                    Section(group.name) {
                        ForEach(group.areas) { area in
                            Text(area.name).tag(area)
                        }
                    }
                }
            }
        } label: {
            Label(areaStore.selected.name, systemImage: "mappin.and.ellipse")
                .frame(minWidth: DS.Size.minimumTapTarget, minHeight: DS.Size.minimumTapTarget)
        }
        .accessibilityLabel("エリアを選択")
        .accessibilityValue(areaStore.selected.name)
    }

    @ViewBuilder
    private var refreshIndicator: some View {
        if viewModel.isLoading, !viewModel.channels.isEmpty {
            ProgressView()
                .padding(DS.Spacing.s)
                .background(.regularMaterial, in: Circle())
                .padding(.top, DS.Spacing.s)
                .accessibilityLabel("更新中")
        }
    }

    /// 再生できない行は、その理由を番組名より先に見せる。
    private func subtitle(for channel: TVerLiveChannel) -> String {
        if let caution = TVerAreaAvailability.rowCaution(for: channel) { return caution }
        return channel.currentProgram?.title ?? "番組情報を取得できませんでした"
    }

    private func detail(for channel: TVerLiveChannel) -> String {
        var parts = [channel.name]
        if let program = channel.currentProgram {
            parts.append(program.timeLabel)
        }
        return parts.joined(separator: "・")
    }

    private func badges(for channel: TVerLiveChannel) -> [MediaBadge] {
        switch channel.state {
        case .onAir: return [MediaBadge(.live)]
        case .paused: return [MediaBadge(.catchUpChecking, text: "配信休止")]
        case .unavailable: return [MediaBadge(.noCatchUp, text: "配信なし")]
        }
    }
}

struct LivePlaybackView: View {
    let channel: TVerLiveChannel
    @ObservedObject var playbackController: PlaybackController
    @StateObject private var pictureInPicture = PictureInPictureCoordinator()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var isFullScreenPresented = false

    private var shareItem: ProgramShareItem { ProgramShareItem(channel: channel) }
    private var isCurrent: Bool { playbackController.currentLiveChannel?.id == channel.id }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    PlaybackVideoSurface(
                        player: playbackController.player,
                        pictureInPicture: pictureInPicture,
                        accessibilityLabel: "\(channel.name)のライブ動画プレイヤー",
                        isActiveSurface: !isFullScreenPresented,
                        onEnterFullScreen: { isFullScreenPresented = true }
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
        .fullScreenCover(isPresented: $isFullScreenPresented) {
            FullScreenPlaybackView(
                playbackController: playbackController,
                pictureInPicture: pictureInPicture,
                title: channel.name,
                subtitle: channel.currentProgram?.seriesTitle,
                accessibilityLabel: "\(channel.name)の全画面ライブ動画プレイヤー",
                supportsSeeking: false,
                onExit: { isFullScreenPresented = false }
            )
        }
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
