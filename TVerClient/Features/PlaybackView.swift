import AVKit
import SwiftUI

/// Episode player screen.
///
/// The video and its controls are one fixed stage at the top of the screen and
/// only the programme information scrolls, so the transport controls can never
/// scroll away or fight the scroll gesture again.
@MainActor
struct PlaybackView: View {
    let program: TVerProgram
    @ObservedObject var playbackController: PlaybackController
    @ObservedObject var libraryStore: ProgramLibraryStore
    @StateObject private var pictureInPicture = PictureInPictureCoordinator()
    @StateObject private var chrome = PlayerChromeModel()
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

    private var relatedPrograms: [TVerProgram] {
        Array(libraryStore.recentPrograms.filter { $0.id != program.id }.prefix(6))
    }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                VStack(spacing: 0) {
                    PlayerStage(
                        playbackController: playbackController,
                        pictureInPicture: pictureInPicture,
                        model: chrome,
                        title: program.seriesTitle,
                        subtitle: program.title,
                        accessibilityLabel: "\(program.seriesTitle)の動画プレイヤー",
                        supportsSeeking: true,
                        isFullScreen: false,
                        isActiveSurface: !isFullScreenPresented,
                        onToggleFullScreen: { isFullScreenPresented = true }
                    )
                    .frame(width: proxy.size.width, height: (proxy.size.width * 9 / 16).rounded())
                    details
                }
            }
            .background(Color(uiColor: .systemBackground))
            .navigationTitle("視聴")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { dismiss() }.frame(minWidth: 44, minHeight: 44)
                }
            }
        }
        .preferredColorScheme(.dark)
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

    private var details: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.l) {
                header
                actionRow
                statusSection
                if !relatedPrograms.isEmpty { relatedSection }
            }
            .padding(DS.Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Text(program.title)
                .font(.title3.bold())
                .fixedSize(horizontal: false, vertical: true)
            Text(program.seriesTitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: DS.Spacing.m) {
                Label(program.broadcastLabel, systemImage: "clock")
                if let availableUntil = program.availableUntil, !availableUntil.isEmpty {
                    Label(availableUntil, systemImage: "calendar.badge.clock")
                }
            }
            .font(DS.Typography.rowDetail)
            .foregroundStyle(.secondary)
            if !program.description.isEmpty {
                Text(program.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actionRow: some View {
        HStack(spacing: DS.Spacing.s) {
            Button { libraryStore.toggleFavorite(program) } label: {
                Label(
                    isFavorite ? "お気に入り済み" : "お気に入り",
                    systemImage: isFavorite ? "heart.fill" : "heart"
                )
                .frame(maxWidth: .infinity, minHeight: DS.Size.minimumTapTarget)
            }
            .buttonStyle(.bordered)
            .tint(isFavorite ? .red : .accentColor)
            .accessibilityLabel(isFavorite ? "お気に入りから削除" : "お気に入りに追加")

            ShareLink(
                item: shareItem.url,
                subject: Text(shareItem.subject),
                message: Text(shareItem.message)
            ) {
                Image(systemName: "square.and.arrow.up")
                    .frame(minWidth: DS.Size.minimumTapTarget, minHeight: DS.Size.minimumTapTarget)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("共有")

            Button { openURL(program.webURL) } label: {
                Image(systemName: "safari")
                    .frame(minWidth: DS.Size.minimumTapTarget, minHeight: DS.Size.minimumTapTarget)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("TVer公式ページで開く")
        }
        .controlSize(.large)
    }

    @ViewBuilder
    private var statusSection: some View {
        if isCurrent, let presentation = playbackController.errorPresentation {
            PlaybackFailureView(presentation: presentation, officialURL: program.webURL) {
                libraryStore.recordRecentlyViewed(program)
                Task { await playbackController.play(program) }
            }
        } else if isCurrent, playbackController.state == .ended {
            Label("再生が終了しました", systemImage: "checkmark.circle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var relatedSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Text("最近見た番組")
                .font(DS.Typography.sectionHeader)
                .foregroundStyle(.secondary)
            ForEach(relatedPrograms, id: \.id) { item in
                MediaRow(
                    title: item.title,
                    subtitle: item.seriesTitle,
                    detail: item.broadcastLabel,
                    thumbnailURL: item.thumbnailURL
                ) {
                    EmptyView()
                }
                .padding(.vertical, DS.Spacing.xxs)
                Divider().overlay(DS.Palette.separator)
            }
        }
    }
}
