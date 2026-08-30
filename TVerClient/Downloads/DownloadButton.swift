import SwiftUI

/// Single control that drives one episode through the whole download state
/// machine. Usable from any screen that can reach a `TVerProgram`.
///
/// Every state keeps the same 44x44pt outer box so rows never reflow while a
/// download progresses.
@MainActor
struct DownloadButton: View {
    let program: TVerProgram

    @EnvironmentObject private var downloadCenter: DownloadCenter
    @State private var showsDeleteConfirmation = false

    init(program: TVerProgram) {
        self.program = program
    }

    private var state: DownloadState { downloadCenter.state(for: program.id) }

    var body: some View {
        Button(action: activate) {
            symbol
                .frame(
                    width: DS.Size.minimumTapTarget,
                    height: DS.Size.minimumTapTarget
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .contextMenu {
            if case .downloading = state {
                Button {
                    downloadCenter.pause(program.id)
                } label: {
                    Label("一時停止", systemImage: "pause.circle")
                }
            }
            if case .paused = state {
                Button {
                    downloadCenter.resume(program.id)
                } label: {
                    Label("再開", systemImage: "play.circle")
                }
            }
            if state.isInFlight {
                Button(role: .destructive) {
                    downloadCenter.cancel(program.id)
                } label: {
                    Label("キャンセル", systemImage: "xmark.circle")
                }
            }
        }
        .confirmationDialog(
            "保存した番組を削除しますか？",
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("削除", role: .destructive) { downloadCenter.delete(program.id) }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("オフラインで見られなくなります。")
        }
    }

    private func activate() {
        switch state {
        case .notDownloaded:
            downloadCenter.start(program)
        case .queued, .downloading:
            downloadCenter.cancel(program.id)
        case .paused:
            downloadCenter.resume(program.id)
        case .failed:
            // A failed row retries straight away; interrupting with an alert
            // only adds a tap to a state the user already understands.
            downloadCenter.retry(program.id)
        case .downloaded:
            showsDeleteConfirmation = true
        }
    }

    @ViewBuilder
    private var symbol: some View {
        switch state {
        case .notDownloaded:
            Image(systemName: "arrow.down.circle")
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(DS.Palette.catchUp)
        case .queued:
            ProgressView()
                .progressViewStyle(.circular)
        case let .downloading(progress):
            ZStack {
                Circle()
                    .stroke(DS.Palette.separator, lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: max(0.02, DownloadCenter.clamp(progress)))
                    .stroke(
                        DS.Palette.catchUp,
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                Image(systemName: "stop.fill")
                    .font(.caption2)
                    .foregroundStyle(DS.Palette.catchUp)
            }
            .frame(width: DS.Size.compactIcon, height: DS.Size.compactIcon)
        case .paused:
            Image(systemName: "play.circle")
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(DS.Palette.catchUp)
        case .failed:
            Image(systemName: "arrow.clockwise.circle")
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(DS.Palette.warning)
        case .downloaded:
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(DS.Palette.downloaded)
        }
    }

    private var accessibilityLabel: String {
        switch state {
        case .notDownloaded:
            return "ダウンロード"
        case .queued:
            return "順番待ち。ダブルタップでキャンセル"
        case let .downloading(progress):
            let percent = Int((DownloadCenter.clamp(progress) * 100).rounded())
            return "ダウンロード中 \(percent)パーセント。ダブルタップでキャンセル"
        case let .paused(progress):
            let percent = Int((DownloadCenter.clamp(progress) * 100).rounded())
            return "一時停止中 \(percent)パーセント。ダブルタップで再開"
        case .failed:
            return "保存に失敗。ダブルタップで再試行"
        case .downloaded:
            return "保存済み。ダブルタップで削除"
        }
    }
}
