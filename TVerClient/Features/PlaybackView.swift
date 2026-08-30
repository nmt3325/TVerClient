import AVKit
import SwiftUI

@MainActor
struct PlaybackView: View {
    let program: TVerProgram
    @ObservedObject var playbackController: PlaybackController
    @ObservedObject var libraryStore: ProgramLibraryStore
    @StateObject private var pictureInPicture = PictureInPictureCoordinator()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var isFullScreenPresented = false

    init(
        program: TVerProgram,
        playbackController: PlaybackController,
        libraryStore: ProgramLibraryStore
    ) {
        self.program = program
        self.playbackController = playbackController
        self.libraryStore = libraryStore
    }

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
                        accessibilityLabel: "\(program.seriesTitle)の動画プレイヤー",
                        isActiveSurface: !isFullScreenPresented,
                        onEnterFullScreen: { isFullScreenPresented = true }
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
        .fullScreenCover(isPresented: $isFullScreenPresented) {
            FullScreenPlaybackView(
                playbackController: playbackController,
                pictureInPicture: pictureInPicture,
                title: program.seriesTitle,
                subtitle: program.title,
                accessibilityLabel: "\(program.seriesTitle)の全画面動画プレイヤー",
                onExit: { isFullScreenPresented = false }
            )
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
