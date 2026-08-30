import SwiftUI

/// Download-first library. The capacity bar sits above three grouped lists:
/// transfers in flight, saved episodes, and the programmes the viewer kept.
@MainActor
struct LibraryView: View {
    @ObservedObject var libraryStore: ProgramLibraryStore
    @ObservedObject var playbackController: PlaybackController
    @EnvironmentObject private var downloadCenter: DownloadCenter

    @State private var selectedProgram: TVerProgram?

    init(libraryStore: ProgramLibraryStore, playbackController: PlaybackController) {
        self.libraryStore = libraryStore
        self.playbackController = playbackController
    }

    private var inFlight: [DownloadRecord] {
        downloadCenter.records.filter { record in !record.state.isFinished }
    }

    private var saved: [DownloadRecord] {
        downloadCenter.records.filter { record in record.state.isFinished }
    }

    private var isEmpty: Bool {
        downloadCenter.records.isEmpty
            && libraryStore.favoritePrograms.isEmpty
            && libraryStore.recentPrograms.isEmpty
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    DownloadStorageBar(usage: downloadCenter.storage)
                        .listRowSeparator(.hidden)
                }

                if let rejection = downloadCenter.lastRejection {
                    Section {
                        rejectionNotice(rejection)
                            .listRowSeparator(.hidden)
                    }
                }

                if isEmpty {
                    Section {
                        ContentStatusView(.empty(
                            title: "保存した番組はありません",
                            message: "番組の右にある保存ボタンを押すと、通信のない場所でも見られます。",
                            systemImage: "arrow.down.circle"
                        ))
                        .listRowSeparator(.hidden)
                    }
                } else {
                    downloadingSection
                    savedSection
                    favoritesSection
                    recentsSection
                }
            }
            .listStyle(.plain)
            .navigationTitle("ライブラリ")
            .toolbar { settingsToolbar }
            .refreshable { downloadCenter.refreshStorage() }
        }
        .sheet(item: $selectedProgram) { program in
            PlaybackView(
                program: program,
                playbackController: playbackController,
                libraryStore: libraryStore
            )
        }
        .onAppear { downloadCenter.refreshStorage() }
    }

    // MARK: - Sections

    @ViewBuilder
    private var downloadingSection: some View {
        if !inFlight.isEmpty {
            Section {
                ForEach(inFlight) { record in
                    row(for: record.program, state: record.state)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                downloadCenter.cancel(record.id)
                            } label: {
                                Label("キャンセル", systemImage: "xmark")
                            }
                            if case .downloading = record.state {
                                Button {
                                    downloadCenter.pause(record.id)
                                } label: {
                                    Label("一時停止", systemImage: "pause")
                                }
                            }
                            if case .paused = record.state {
                                Button {
                                    downloadCenter.resume(record.id)
                                } label: {
                                    Label("再開", systemImage: "play")
                                }
                            }
                        }
                }
            } header: {
                SectionHeader("ダウンロード中", subtitle: "\(inFlight.count)件")
            }
        }
    }

    @ViewBuilder
    private var savedSection: some View {
        if !saved.isEmpty {
            Section {
                ForEach(saved) { record in
                    row(for: record.program, state: record.state)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                downloadCenter.delete(record.id)
                            } label: {
                                Label("削除", systemImage: "trash")
                            }
                        }
                }
            } header: {
                SectionHeader(
                    "保存済み",
                    subtitle: DownloadStorageBar.formatted(downloadCenter.storage.usedBytes)
                )
            }
        }
    }

    @ViewBuilder
    private var favoritesSection: some View {
        if !libraryStore.favoritePrograms.isEmpty {
            Section {
                ForEach(libraryStore.favoritePrograms) { program in
                    row(for: program, state: downloadCenter.state(for: program.id))
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                libraryStore.removeFavorite(program)
                            } label: {
                                Label("マイリストから削除", systemImage: "heart.slash")
                            }
                        }
                }
            } header: {
                SectionHeader(
                    "マイリスト",
                    subtitle: "\(libraryStore.favoritePrograms.count)件"
                ) {
                    Button("すべて削除") { libraryStore.clearFavorites() }
                        .font(.caption2)
                        .buttonStyle(.plain)
                        .foregroundStyle(DS.Palette.catchUp)
                }
            }
        }
    }

    @ViewBuilder
    private var recentsSection: some View {
        if !libraryStore.recentPrograms.isEmpty {
            Section {
                ForEach(libraryStore.recentPrograms) { program in
                    row(for: program, state: downloadCenter.state(for: program.id))
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                libraryStore.removeRecentProgram(program)
                            } label: {
                                Label("履歴から削除", systemImage: "trash")
                            }
                        }
                }
            } header: {
                SectionHeader(
                    "最近見た",
                    subtitle: "\(libraryStore.recentPrograms.count)件"
                ) {
                    Button("履歴を消去") { libraryStore.clearRecentPrograms() }
                        .font(.caption2)
                        .buttonStyle(.plain)
                        .foregroundStyle(DS.Palette.catchUp)
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var settingsToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                Toggle("Wi-Fiのときだけ保存", isOn: $downloadCenter.wifiOnly)
                Toggle("視聴後に自動削除", isOn: $downloadCenter.deleteAfterWatching)
                Divider()
                Button {
                    downloadCenter.refreshStorage()
                } label: {
                    Label("空き容量を再計算", systemImage: "arrow.clockwise")
                }
            } label: {
                Image(systemName: "gearshape")
                    .frame(
                        width: DS.Size.minimumTapTarget,
                        height: DS.Size.minimumTapTarget
                    )
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("ダウンロード設定")
        }
    }

    // MARK: - Rows

    private func row(for program: TVerProgram, state: DownloadState) -> some View {
        MediaRow(
            title: program.seriesTitle.isEmpty ? program.title : program.seriesTitle,
            subtitle: program.title,
            detail: detail(for: program, state: state),
            thumbnailURL: program.thumbnailURL,
            badges: badges(for: state),
            progress: state.progress
        ) {
            DownloadButton(program: program)
        }
        .contentShape(Rectangle())
        .onTapGesture { open(program) }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text("再生")) { open(program) }
    }

    private func rejectionNotice(_ rejection: DownloadCenter.Rejection) -> some View {
        HStack(alignment: .top, spacing: DS.Spacing.s) {
            Image(systemName: "exclamationmark.circle")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(DS.Palette.warning)
            Text(rejection.message)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button {
                downloadCenter.clearRejection()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
                    .frame(
                        width: DS.Size.minimumTapTarget,
                        height: DS.Size.minimumTapTarget
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("このお知らせを閉じる")
        }
    }

    private func badges(for state: DownloadState) -> [MediaBadge] {
        switch state {
        case .notDownloaded:
            return []
        case .queued, .downloading:
            return [MediaBadge(.downloading)]
        case .paused:
            return [MediaBadge(.downloading, text: "一時停止")]
        case .failed:
            return [MediaBadge(.expiringSoon, text: "保存失敗")]
        case .downloaded:
            return [MediaBadge(.downloaded)]
        }
    }

    private func detail(for program: TVerProgram, state: DownloadState) -> String? {
        switch state {
        case .notDownloaded:
            if let availableUntil = program.availableUntil, !availableUntil.isEmpty {
                return "配信期限 \(availableUntil)"
            }
            return program.broadcastLabel
        case .queued:
            return "順番待ち"
        case let .downloading(progress):
            return "ダウンロード中 \(percent(progress))"
        case let .paused(progress):
            return "一時停止中 \(percent(progress))"
        case let .failed(message):
            return message
        case let .downloaded(bytes):
            return DownloadStorageBar.formatted(bytes)
        }
    }

    private func percent(_ progress: Double) -> String {
        "\(Int((DownloadCenter.clamp(progress) * 100).rounded()))%"
    }

    private func open(_ program: TVerProgram) {
        DiagnosticLogStore.shared.record(
            .info,
            category: "library",
            message: "Library row opened for playback"
        )
        selectedProgram = program
    }
}
