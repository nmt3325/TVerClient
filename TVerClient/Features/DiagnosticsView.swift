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
    @State private var isExporting = false
    @State private var exportDocument = DiagnosticLogDocument(text: "")
    @State private var exportError: String?
    @State private var showsClearConfirmation = false

    init(
        logStore: DiagnosticLogStore = .shared,
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

private extension DiagnosticLogLevel {
    var color: Color {
        switch self {
        case .info: return .secondary
        case .warning: return .orange
        case .error: return .red
        }
    }
}
