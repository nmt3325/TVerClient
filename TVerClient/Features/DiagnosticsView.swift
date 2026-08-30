import SwiftUI
import UniformTypeIdentifiers

struct DiagnosticLogDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        text = configuration.file.regularFileContents
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

@MainActor
struct DiagnosticsView: View {
    @ObservedObject var logStore: DiagnosticLogStore
    private let networkService: NetworkDiagnosticsService

    @State private var results: [NetworkDiagnosticResult] = []
    @State private var isRunning = false
    @State private var isSelfChecking = false
    @State private var isExporting = false
    @State private var exportDocument = DiagnosticLogDocument(text: "")
    @State private var exportError: String?
    @State private var showsClearConfirmation = false

    init(
        logStore: DiagnosticLogStore,
        networkService: NetworkDiagnosticsService = NetworkDiagnosticsService()
    ) {
        self.logStore = logStore
        self.networkService = networkService
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("LiveContainerなどで問題が発生した場合、通信診断を実行してからログを書き出してください。")
                    Text("トークン、Cookie、リクエストヘッダー、URLのクエリ、実際の配信URLは記録しません。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("使い方")
                }

                Section("通信診断") {
                    Button {
                        Task { await runDiagnostics() }
                    } label: {
                        Label(isRunning ? "診断中…" : "通信診断を実行", systemImage: "network")
                    }
                    .disabled(isRunning)

                    ForEach(results, id: \.target) { result in
                        HStack {
                            Label(result.target.displayName, systemImage: result.isReachable ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(result.isReachable ? Color.green : Color.red)
                            Spacer()
                            Text(result.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }

                Section("起動セルフチェック") {
                    Button {
                        Task { await runSelfCheck() }
                    } label: {
                        Label(
                            isSelfChecking ? "実行中…" : "セルフチェックを実行",
                            systemImage: "stethoscope"
                        )
                    }
                    .disabled(isSelfChecking)

                    if let report = logStore.selfCheckReport {
                        HStack {
                            Label(report.status.badgeTitle, systemImage: report.status.systemImage)
                                .font(.caption.bold())
                                .foregroundStyle(report.status.color)
                            Spacer()
                            Text(report.startedAt, style: .time)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)

                        ForEach(report.steps) { step in
                            HStack(alignment: .firstTextBaseline) {
                                Text(step.name)
                                    .font(.caption.bold())
                                Spacer()
                                Text(step.line)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(step.isOK ? Color.secondary : Color.orange)
                                    .multilineTextAlignment(.trailing)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    } else {
                        Text(
                            "このセッションでは未実行です。起動時の自動実行は統合作業で App 側に配線する必要があります。"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }

                Section("エンドポイント別サマリ") {
                    if healthSummaries.isEmpty {
                        Text("まだ計測結果がありません")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(healthSummaries) { summary in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Label(
                                        summary.endpoint.displayName,
                                        systemImage: summary.isHealthy
                                            ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                                    )
                                    .font(.caption.bold())
                                    .foregroundStyle(summary.isHealthy ? Color.green : Color.orange)
                                    Spacer()
                                    if let outcome = summary.lastOutcome {
                                        Text(outcome.badgeTitle)
                                            .font(.caption2.bold())
                                            .foregroundStyle(outcome.color)
                                    }
                                }
                                Text(summary.countsDescription)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }

                Section("最近の失敗・フォールバック") {
                    if recentProblems.isEmpty {
                        Text("失敗やフォールバックは記録されていません")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(recentProblems) { event in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(event.outcome.badgeTitle)
                                        .font(.caption2.bold())
                                        .foregroundStyle(event.outcome.color)
                                    Text(event.endpoint.displayName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text(event.at, style: .time)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Text(EndpointHealthStore.describe(event))
                                    .font(.caption2.monospaced())
                                    .textSelection(.enabled)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }

                Section("書き出し") {
                    Button {
                        exportDocument = DiagnosticLogDocument(text: logStore.exportText())
                        isExporting = true
                    } label: {
                        Label("ログを書き出す", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityHint("個人情報を除去したテキストログをファイルへ保存します")

                    Button(role: .destructive) {
                        showsClearConfirmation = true
                    } label: {
                        Label("ログを消去", systemImage: "trash")
                    }

                    if let exportError {
                        Text(exportError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section("最近のログ（\(logStore.entries.count)件）") {
                    if logStore.entries.isEmpty {
                        Text("ログはまだありません")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(logStore.entries.suffix(100).reversed()) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(entry.level.rawValue)
                                        .font(.caption2.bold())
                                        .foregroundStyle(entry.level.color)
                                    Text(entry.category)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text(entry.timestamp, style: .time)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Text(entry.message)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            .navigationTitle("診断ログ")
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .plainText,
            defaultFilename: exportFilename
        ) { result in
            switch result {
            case .success:
                exportError = nil
                logStore.record(.info, category: "diagnostics", message: "Diagnostic log exported")
            case .failure(let error):
                exportError = "書き出しに失敗しました: \(DiagnosticLogStore.sanitize(error.localizedDescription))"
                logStore.record(.error, category: "diagnostics", message: exportError ?? "Log export failed")
            }
        }
        .confirmationDialog("診断ログを消去しますか？", isPresented: $showsClearConfirmation) {
            Button("消去", role: .destructive) { logStore.clear() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("保存済みの診断ログを削除します。")
        }
    }

    /// Recomputed from the shared health store. Every non-ok event also lands
    /// in `logStore.entries`, so the published change that redraws the log
    /// section redraws these two sections as well.
    private var healthSummaries: [EndpointHealthSummary] { logStore.endpointHealth }

    private var recentProblems: [EndpointHealthEvent] { logStore.recentHealthProblems(limit: 20) }

    private func runSelfCheck() async {
        guard !isSelfChecking else { return }
        isSelfChecking = true
        await StartupSelfCheck.run(service: networkService, store: logStore)
        isSelfChecking = false
    }

    private func runDiagnostics() async {
        guard !isRunning else { return }
        isRunning = true
        logStore.record(.info, category: "network", message: "Manual network diagnostics started")
        let newResults = await networkService.run()
        results = newResults
        for result in newResults {
            logStore.record(
                result.isReachable ? .info : .error,
                category: "network",
                message: "Connectivity probe completed",
                metadata: [
                    "target": result.target.rawValue,
                    "reachability": result.reachability.rawValue,
                    "stage": result.failureStage?.rawValue ?? "none",
                    "httpStatus": result.statusCode.map(String.init) ?? "none",
                ]
            )
        }
        isRunning = false
    }

    private var exportFilename: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "TVerClient-diagnostics-\(formatter.string(from: Date()))"
    }
}

private extension NetworkDiagnosticTarget {
    var displayName: String {
        switch self {
        case .tver: return "TVer"
        case .streaks: return "Streaks配信基盤"
        }
    }
}

private extension NetworkDiagnosticResult {
    var isReachable: Bool { reachability == .reachable && failureStage == nil }

    var summary: String {
        if let failureStage { return "失敗: \(failureStage.rawValue)" }
        if let statusCode { return "HTTP \(statusCode)" }
        return reachability.rawValue
    }
}

private extension EndpointID {
    var displayName: String {
        switch self {
        case .programGuide: return "番組表API"
        case .liveChannels: return "ライブチャンネルAPI"
        case .episodeDetail: return "エピソード情報"
        case .catchUpSearch: return "見逃し検索"
        case .liveManifest: return "ライブ配信基盤"
        case .vodPlaybackAPI: return "見逃し配信API"
        case .mediaManifest: return "配信マニフェスト"
        }
    }
}

private extension EndpointOutcome {
    var badgeTitle: String {
        switch self {
        case .ok: return "正常"
        case .degraded: return "劣化"
        case .fallbackUsed: return "フォールバック"
        case .failed: return "失敗"
        }
    }

    var color: Color {
        switch self {
        case .ok: return .green
        case .degraded: return .yellow
        case .fallbackUsed: return .orange
        case .failed: return .red
        }
    }
}

private extension EndpointHealthSummary {
    var countsDescription: String {
        "正常 \(okCount) / 劣化 \(degradedCount) / フォールバック \(fallbackUsedCount) / 失敗 \(failedCount)"
    }
}

private extension StartupSelfCheckStatus {
    var badgeTitle: String {
        switch self {
        case .ok: return "セルフチェック: 正常"
        case .degraded: return "セルフチェック: 劣化"
        case .failed: return "セルフチェック: 失敗"
        }
    }

    var systemImage: String {
        switch self {
        case .ok: return "checkmark.seal.fill"
        case .degraded: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .ok: return .green
        case .degraded: return .orange
        case .failed: return .red
        }
    }
}

private extension DiagnosticLogLevel {
    var color: Color {
        switch self {
        case .info: return .secondary
        case .warning: return .orange
        case .error: return .red
        }
    }
}
