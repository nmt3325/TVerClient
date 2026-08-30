import AVKit
import SwiftUI

enum ProgramLibrarySection: String, CaseIterable, Identifiable {
    case favorites = "お気に入り"
    case recents = "最近見た"
    var id: String { rawValue }
}

struct LibraryView: View {
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

struct LibraryProgramRow: View {
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
