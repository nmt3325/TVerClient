import AVKit
import SwiftUI

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

struct LiveView: View {
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

struct LiveChannelCard: View {
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
