import SwiftUI

/// Single control that drives one episode through the whole download state
/// machine. Usable from any screen that can reach a `TVerProgram`.
///
/// Every state keeps the same 44x44pt outer box so rows never reflow while a
/// download progresses.
///
/// 中止と削除は、ボタンからでも長押しメニューからでも同じ確認を通す。
@MainActor
struct DownloadButton: View {
    let program: TVerProgram

    @EnvironmentObject private var downloadCenter: DownloadCenter
    @State private var pendingConfirmation: DownloadConfirmation?

    init(program: TVerProgram) {
        self.program = program
    }

    private var state: DownloadState { downloadCenter.state(for: program.id) }

    enum PrimaryAction: Equatable {
        case start, cancel, pause, resume, restart, retry, savedOptions

        var label: String {
            switch self {
            case .start: return Vocabulary.Download.action
            case .cancel: return Vocabulary.Download.cancel
            case .pause: return "ダウンロードを一時停止"
            case .resume: return Vocabulary.Download.resume
            case .restart: return "最初からやり直す"
            case .retry: return "最初から再試行"
            case .savedOptions: return "ダウンロード済みの操作"
            }
        }
    }

    /// 進行中の主操作は取り消せる一時停止。データを捨てる中止は確認付きメニューへ。
    static func primaryAction(for state: DownloadState, isInterrupted: Bool) -> PrimaryAction {
        switch state {
        case .notDownloaded: return .start
        case .queued: return .cancel
        case .downloading: return .pause
        case .paused: return isInterrupted ? .restart : .resume
        case .failed: return .retry
        case .downloaded: return .savedOptions
        }
    }

    private var primaryAction: PrimaryAction {
        Self.primaryAction(for: state, isInterrupted: isInterrupted)
    }

    /// 続きから戻せない一時停止。同じ見た目で押しても進まない状態を作らない。
    private var isInterrupted: Bool { downloadCenter.isInterrupted(program.id) }

    private var isCancellable: Bool {
        switch state {
        case .queued, .downloading, .paused, .failed:
            return true
        case .notDownloaded, .downloaded:
            return false
        }
    }

    var body: some View {
        primaryControl
            .buttonStyle(.plain)
            .accessibilityLabel("\(title)の\(primaryAction.label)")
            .accessibilityValue(accessibilityValue)
            .accessibilityHint(state.isFinished ? "メニューから削除を選ぶと確認が表示されます" : primaryAction.label)
            .accessibilityAddTraits(.isButton)
            .contextMenu { contextActions }
            .confirmationDialog(
                Text(pendingConfirmation?.title ?? ""),
                isPresented: Binding(
                    get: { pendingConfirmation != nil },
                    set: { isPresented in
                        if !isPresented { pendingConfirmation = nil }
                    }
                ),
                titleVisibility: .visible,
                presenting: pendingConfirmation
            ) { confirmation in
                Button(
                    confirmation.confirmLabel,
                    role: confirmation.isDestructive ? ButtonRole.destructive : nil
                ) {
                    perform(confirmation.target)
                    pendingConfirmation = nil
                }
                Button("やめる", role: .cancel) { pendingConfirmation = nil }
            } message: { confirmation in
                Text(confirmation.message)
            }
    }

    @ViewBuilder
    private var primaryControl: some View {
        if state.isFinished {
            // 完了のチェックマークを押すだけで、削除へ直行させない。
            Menu { contextActions } label: { symbolBox }
        } else {
            Button(action: activate) { symbolBox }
        }
    }

    private var symbolBox: some View {
        symbol
            .frame(width: DS.Size.minimumTapTarget, height: DS.Size.minimumTapTarget)
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private var contextActions: some View {
        if case .downloading = state {
            Button {
                downloadCenter.pause(program.id)
            } label: {
                Label("一時停止", systemImage: "pause.circle")
            }
        }
        if case .paused = state {
            Button {
                resumeOrRestart()
            } label: {
                Label(
                    isInterrupted ? "最初からやり直す" : Vocabulary.Download.resume,
                    systemImage: isInterrupted ? "arrow.clockwise.circle" : "play.circle"
                )
            }
        }
        if case .failed = state {
            Button {
                downloadCenter.retry(program.id)
            } label: {
                Label(
                    "最初から再試行",
                    systemImage: "arrow.clockwise.circle"
                )
            }
        }
        // 一時停止中や失敗後でも中止できないと、一覧から消す手段がなくなる。
        if isCancellable {
            Button(role: .destructive) {
                confirm(.runningDownload)
            } label: {
                Label(Vocabulary.Download.cancel, systemImage: "xmark.circle")
            }
        }
        if state.isFinished {
            Button(role: .destructive) {
                confirm(.savedDownload)
            } label: {
                Label(Vocabulary.Download.remove, systemImage: "trash")
            }
        }
    }

    private func activate() {
        switch primaryAction {
        case .start:
            downloadCenter.start(program)
        case .cancel:
            confirm(.runningDownload)
        case .pause:
            downloadCenter.pause(program.id)
        case .resume, .restart:
            resumeOrRestart()
        case .retry:
            downloadCenter.retry(program.id)
        case .savedOptions:
            break // 保存済みの主操作はMenuで受ける。
        }
    }

    private func resumeOrRestart() {
        guard isInterrupted else {
            downloadCenter.resume(program.id)
            return
        }
        confirm(.restartDownload)
    }

    private func confirm(_ target: DownloadConfirmation.Target) {
        pendingConfirmation = DownloadConfirmation(target: target, subject: title)
    }

    private func perform(_ target: DownloadConfirmation.Target) {
        switch target {
        case .runningDownload:
            guard isCancellable else { return }
            downloadCenter.cancel(program.id)
        case .savedDownload:
            guard state.isFinished else { return }
            downloadCenter.delete(program.id)
        case .restartDownload:
            guard case .paused = state, isInterrupted else { return }
            downloadCenter.restart(program)
        case .favorite, .allFavorites, .recent, .allRecents, .selection:
            break
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
            Image(systemName: "xmark.circle")
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(DS.Palette.catchUp)
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
                Image(systemName: "pause.fill")
                    .font(.caption2)
                    .foregroundStyle(DS.Palette.catchUp)
            }
            .frame(width: DS.Size.compactIcon, height: DS.Size.compactIcon)
        case .paused:
            Image(systemName: isInterrupted ? "arrow.clockwise.circle" : "play.circle")
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isInterrupted ? DS.Palette.warning : DS.Palette.catchUp)
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

    private var title: String {
        program.seriesTitle.isEmpty ? program.title : program.seriesTitle
    }

    /// ラベルは操作、値は現在の状態を伝える。
    private var accessibilityValue: String {
        switch state {
        case .notDownloaded:
            return ""
        case .queued:
            return Vocabulary.Download.queued
        case let .downloading(progress):
            return "\(Vocabulary.Download.running) \(percent(progress))パーセント"
        case let .paused(progress):
            guard isInterrupted else {
                return "\(Vocabulary.Download.paused) \(percent(progress))パーセント"
            }
            return "\(Vocabulary.Download.paused) \(percent(progress))パーセント。続きからは再開できません"
        case let .failed(message):
            return message
        case .downloaded:
            return Vocabulary.Library.downloads
        }
    }

    private func percent(_ progress: Double) -> Int {
        Int((DownloadCenter.clamp(progress) * 100).rounded())
    }
}
