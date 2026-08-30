import SwiftUI
import UIKit
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
    @State private var copyConfirmation: String?
    @State private var isGlossaryExpanded = false

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
                } footer: {
                    Text("不具合を伝えるときは「通信診断を実行」→「ログを共有」の順に押してください。見慣れない言葉は一番下の「用語の説明」にまとめてあります。")
                }

                Section("通信診断") {
                    Text("この端末から TVer と配信基盤（Streaks）につながるかを、実際に接続して確かめます。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        Task { await runDiagnostics() }
                    } label: {
                        Label(isRunning ? "診断中…" : "通信診断を実行", systemImage: "network")
                    }
                    .disabled(isRunning)

                    ForEach(results, id: \.target) { result in
                        HStack {
                            Label(result.target.displayName, systemImage: result.isReachable ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(result.isReachable ? DS.Palette.downloaded : DS.Palette.live)
                            Spacer()
                            Text(result.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }

                Section("起動セルフチェック") {
                    Text("アプリの起動に必要な問い合わせを一通り試して、どこで止まるかを調べます。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
                                    .foregroundStyle(step.isOK ? Color.secondary : DS.Palette.warning)
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
                    Text("エンドポイントは、番組表や配信URLを取りに行く問い合わせ先のことです。先別に成否の回数を数えています。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
                                    .foregroundStyle(summary.isHealthy ? DS.Palette.downloaded : DS.Palette.warning)
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
                    Text("フォールバックは、本来の取得に失敗したため別の手段で表示したという意味です。表示できていても内容が古いことがあります。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
                            .contextMenu {
                                Button {
                                    copyToPasteboard(EndpointHealthStore.describe(event), label: "この記録")
                                } label: {
                                    Label("この記録をコピー", systemImage: "doc.on.doc")
                                }
                            }
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

                    Button {
                        copyToPasteboard(logStore.exportText(), label: "診断ログ")
                    } label: {
                        Label("ログをコピー", systemImage: "doc.on.doc")
                    }
                    .accessibilityHint("個人情報を除去したテキストログをクリップボードへコピーします")

                    // ファイル保存を経由せず、メールやメッセージにそのまま渡せるようにする。
                    ShareLink(
                        item: logStore.exportText(),
                        subject: Text("TVer Client 診断ログ"),
                        message: Text("個人情報を除いた診断ログです。")
                    ) {
                        Label("ログを共有", systemImage: "square.and.arrow.up.on.square")
                    }
                    .accessibilityHint("他のアプリへ診断ログをそのまま渡します")

                    if let copyConfirmation {
                        Label(copyConfirmation, systemImage: "checkmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(DS.Palette.downloaded)
                    }

                    Button(role: .destructive) {
                        showsClearConfirmation = true
                    } label: {
                        Label("ログを消去", systemImage: "trash")
                            .frame(minHeight: DS.Size.minimumTapTarget)
                    }
                    .accessibilityLabel("診断ログをすべて消去")
                    .accessibilityHint("確認してから削除します。消去後は元に戻せません")

                    if let exportError {
                        Text(exportError)
                            .font(.footnote)
                            .foregroundStyle(DS.Palette.live)
                    }
                }

                Section {
                    DisclosureGroup(isExpanded: $isGlossaryExpanded) {
                        ForEach(DiagnosticsGlossary.terms) { term in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(term.name)
                                    .font(.caption.bold())
                                Text(term.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.vertical, 2)
                            .accessibilityElement(children: .combine)
                        }
                    } label: {
                        Label("用語の説明", systemImage: "text.book.closed")
                            .frame(minHeight: DS.Size.minimumTapTarget)
                    }
                    .accessibilityHint("この画面に出てくる言葉の意味を開きます")
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
                            .contextMenu {
                                Button {
                                    copyToPasteboard(
                                        "[\(entry.level.rawValue)] \(entry.category) \(entry.message)",
                                        label: "この行"
                                    )
                                } label: {
                                    Label("この行をコピー", systemImage: "doc.on.doc")
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
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
            Text("記録済みのログとエンドポイントの集計をすべて削除します。元には戻せません。必要なら先に「ログを共有」か「ログを書き出す」で保存してください。")
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

    /// Sharing a file is awkward inside LiveContainer, so the log can also go
    /// straight to the clipboard for pasting into a bug report.
    private func copyToPasteboard(_ text: String, label: String) {
        UIPasteboard.general.string = text
        copyConfirmation = "\(label)をコピーしました"
        logStore.record(.info, category: "diagnostics", message: "Diagnostic text copied")
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            copyConfirmation = nil
        }
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
        case .ok: return DS.Palette.downloaded
        case .degraded: return DS.Palette.warning
        case .fallbackUsed: return DS.Palette.catchUp
        case .failed: return DS.Palette.live
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
        case .ok: return DS.Palette.downloaded
        case .degraded: return DS.Palette.warning
        case .failed: return DS.Palette.live
        }
    }
}

private extension DiagnosticLogLevel {
    var color: Color {
        switch self {
        case .info: return DS.Palette.inactive
        case .warning: return DS.Palette.warning
        case .error: return DS.Palette.live
        }
    }
}

/// 診断画面に出てくる専門用語の短い説明。
///
/// この画面は不具合を伝えるためのものなので、読む人が開発者とは限らない。
/// 用語を残したまま、意味をその場で引けるようにする。
enum DiagnosticsGlossary {
    struct Term: Identifiable {
        let id: String
        let name: String
        let summary: String
    }

    static let terms: [Term] = [
        Term(
            id: "network-diagnostics",
            name: "通信診断",
            summary: "この端末から TVer と配信基盤につながるかを、実際に接続して確かめる操作です。"
        ),
        Term(
            id: "self-check",
            name: "セルフチェック",
            summary: "アプリの起動に必要な問い合わせを一通り試して、どこで止まるかを調べる操作です。"
        ),
        Term(
            id: "endpoint",
            name: "エンドポイント",
            summary: "アプリが番組表や配信URLを取りに行く、問い合わせ先のことです。"
        ),
        Term(
            id: "fallback",
            name: "フォールバック",
            summary: "本来の取得に失敗したため、別の手段で表示したという意味です。表示できていても内容が古いことがあります。"
        ),
        Term(
            id: "degraded",
            name: "劣化",
            summary: "表示はできたものの、一部の情報が取れなかった状態です。"
        ),
        Term(
            id: "dns",
            name: "DNS",
            summary: "tver.jp のような名前を、通信に使う番号に変換する仕組みです。ここで失敗すると接続先が見つかりません。"
        ),
        Term(
            id: "tls",
            name: "TLS",
            summary: "通信を暗号化する仕組みです。ここで失敗するときは、端末の日付設定やネットワーク機器が原因のことがあります。"
        ),
        Term(
            id: "http-status",
            name: "HTTP ステータス",
            summary: "問い合わせ先からの返事の種類を表す 3 桁の番号です。200 は成功、403 や 404 は拒否や不在を意味します。"
        ),
    ]
}
