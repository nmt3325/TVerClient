import AVKit
import SwiftUI

@MainActor
final class LiveViewModel: ObservableObject {
    @Published private(set) var channels: [TVerLiveChannel] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    /// 直近の取得で使ったエリア。エリアを切り替えたときだけ取り直すために持つ。
    @Published private(set) var loadedArea: TVerArea?
    /// いま画面に出ている一覧をどこまで信用してよいか。
    ///
    /// 引き下げ更新が失敗してもスピナーが消えるだけだと、古い一覧を最新だと
    /// 信じ続けてしまう。契約の `LoadFreshness` を publish し、`FreshnessBanner`
    /// から必ず告知する。
    @Published private(set) var freshness: LoadFreshness?
    /// 一覧が一件も無いまま失敗したときの表示。次に何をすればよいかまで持つ。
    @Published private(set) var errorPresentation: TVerErrorPresentation?

    private let service: any TVerLiveServicing
    /// エリア対応の実装を持っているサービスならこちらを使う。init のシグネチャは
    /// 契約で固定なので、ここでキャストして拾う。
    private let areaService: (any TVerAreaAwareServicing)?
    /// 鮮度付きで返せるサービスならこちらを使う。キャッシュ代替表示を
    /// 「最新の情報です」と言わないために、取得元と取得時刻ごと受け取る。
    private let snapshotProvider: (any TVerLiveSnapshotProviding)?
    private let usesPreviewFallback: Bool
    private var hasLoaded = false
    private var currentArea: TVerArea?
    /// 最後に取得できた時刻。更新に失敗したとき「いつの内容か」を言うために持つ。
    private var lastSuccessAt: Date?
    /// 走っている取得。エリアを切り替えるときはこれを畳んでから始める。
    private var loadTask: Task<Bool, Never>?

    init(service: any TVerLiveServicing, usesPreviewFallback: Bool = true) {
        self.service = service
        areaService = service as? any TVerAreaAwareServicing
        snapshotProvider = service as? any TVerLiveSnapshotProviding
        self.usesPreviewFallback = usesPreviewFallback
    }

    /// エリア切替をサービス側が理解できるか。
    var supportsAreaSwitching: Bool { areaService != nil }

    /// 配信中（即座に見られる）チャンネル数。
    var playableChannelCount: Int { channels.filter(\.isPlayable).count }

    func loadIfNeeded() async {
        await loadIfNeeded(area: currentArea)
    }

    func loadIfNeeded(area: TVerArea?) async {
        guard !hasLoaded || loadedArea?.code != area?.code else { return }
        _ = await load(area: area, forceRefresh: false)
    }

    @discardableResult
    func load() async -> Bool {
        await load(area: currentArea, forceRefresh: false)
    }

    /// 取得できたかを返す。エリア切替はこの結果を見て、失敗なら選択を元に戻す。
    @discardableResult
    func load(area: TVerArea?) async -> Bool {
        await load(area: area, forceRefresh: false)
    }

    /// 引き下げ更新。エリア別キャッシュを跨いで取り直す。
    func refresh() async {
        _ = await load(area: currentArea, forceRefresh: true)
    }

    /// 取得を1本ずつに直列化する。
    ///
    /// 以前は実行中なら false を返していたが、呼び出し側（エリア切替）は false を
    /// 一律に取得失敗と読むため、何も失敗していないのに選択が巻き戻り、誤った
    /// 警告まで出ていた。走っている取得を畳んでから始めれば、戻り値は本当の成否だけを表す。
    private func load(area: TVerArea?, forceRefresh: Bool) async -> Bool {
        let running = loadTask
        running?.cancel()
        _ = await running?.value

        let task = Task { @MainActor in
            await self.performLoad(area: area, forceRefresh: forceRefresh)
        }
        loadTask = task
        let succeeded = await task.value
        if loadTask == task { loadTask = nil }
        return succeeded
    }

    private func performLoad(area: TVerArea?, forceRefresh: Bool) async -> Bool {
        currentArea = area
        isLoading = true
        errorMessage = nil
        errorPresentation = nil
        defer { isLoading = false }

        do {
            let snapshot = try await liveSnapshot(area: area, forceRefresh: forceRefresh)
            // 取り消された取得の結果は画面に出さない。新しいエリアの取得が続いている。
            if Task.isCancelled { return false }
            #if DEBUG
                let resolved = snapshot.channels.isEmpty && usesPreviewFallback
                    ? PreviewFixture.liveChannels
                    : snapshot.channels
            #else
                let resolved = snapshot.channels
            #endif
            channels = resolved
            hasLoaded = true
            loadedArea = area
            // キャッシュで凪いだときは成功時刻を更新しない。
            if case let .fresh(at) = snapshot.freshness { lastSuccessAt = at }
            // 取得元と取得時刻をそのまま画面へ渡す。代替表示を最新扱いにしない。
            freshness = snapshot.freshness
            return true
        } catch {
            if Task.isCancelled { return false }
            let normalized = TVerClientError.normalized(from: error)
            let presentation = normalized.presentation
            errorMessage = normalized.errorDescription ?? error.localizedDescription
            errorPresentation = presentation
            // 一覧が残っていても、古いままのものを黙って見せ続けない。
            freshness = .refreshFailed(
                lastGoodAt: lastSuccessAt,
                message: presentation.message,
                recovery: presentation.recoverySuggestion
            )
            DiagnosticLogStore.shared.record(
                .error,
                category: "live-catalog",
                message: "Live channel loading failed",
                metadata: ["error": error.localizedDescription]
            )
            return false
        }
    }

    /// 鮮度付きで返せるサービスならそのまま使い、そうでなければ取得できた時点を
    /// 取得時刻として包む。
    private func liveSnapshot(area: TVerArea?, forceRefresh: Bool) async throws -> LiveChannelsSnapshot {
        if let snapshotProvider {
            return try await snapshotProvider.fetchLiveChannelsSnapshot(
                area: area,
                forceRefresh: forceRefresh
            )
        }
        let response: [TVerLiveChannel]
        if let areaService {
            response = try await areaService.fetchLiveChannels(area: area, forceRefresh: forceRefresh)
        } else {
            response = try await service.fetchLiveChannels(forceRefresh: forceRefresh)
        }
        return LiveChannelsSnapshot(channels: response, freshness: .fresh(at: Date()))
    }
}

@MainActor
struct LiveView: View {
    @StateObject private var viewModel: LiveViewModel
    @ObservedObject private var playbackController: PlaybackController
    @EnvironmentObject private var areaStore: AreaStore
    @Environment(\.openURL) private var openURL
    @State private var selectedChannel: TVerLiveChannel?

    init(viewModel: LiveViewModel, playbackController: PlaybackController) {
        _viewModel = StateObject(wrappedValue: viewModel)
        self.playbackController = playbackController
    }

    var body: some View {
        NavigationStack {
            content
                .safeAreaInset(edge: .top, spacing: 0) { notices }
                .navigationTitle("ライブ")
                .toolbar {
                    ToolbarItem(placement: ToolbarCompat.trailing) { areaPicker }
                }
        }
        .task { await viewModel.loadIfNeeded(area: areaStore.selected) }
        .onChange(of: areaStore.selected) { newArea in
            // 画面から切り替えた分は `switchArea(to:)` が自分で取り直す。ここで拾うのは
            // 起動時のエリア一覧更新のような、外からの変更だけ。
            guard !areaStore.isSwitchingArea else { return }
            Task { await viewModel.loadIfNeeded(area: newArea) }
        }
        .sheet(item: $selectedChannel) { channel in
            LivePlaybackView(channel: channel, playbackController: playbackController)
        }
    }

    /// 一覧の上に常騐する告知。古い一覧を見ていることと、エリア切替の失敗を黙らせない。
    @ViewBuilder
    private var notices: some View {
        VStack(spacing: 0) {
            if let message = areaStore.areaSwitchFailureMessage {
                areaSwitchFailureBanner(message)
            }
            if !viewModel.channels.isEmpty,
               let freshness = viewModel.freshness,
               freshness.isDegraded {
                FreshnessBanner(
                    freshness: freshness,
                    retry: { Task { await viewModel.refresh() } }
                )
            }
        }
    }

    private func areaSwitchFailureBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: DS.Spacing.s) {
            Image(systemName: "mappin.slash")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(DS.Palette.warning)
                .accessibilityHidden(true)
            Text(message)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                areaStore.clearAreaSwitchFailure()
            } label: {
                Image(systemName: "xmark")
                    .frame(width: DS.Size.minimumTapTarget, height: DS.Size.minimumTapTarget)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("エリア切替のお知らせを閉じる")
        }
        .padding(.leading, DS.Spacing.l)
        .padding(.vertical, DS.Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.warning.opacity(0.14))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading, viewModel.channels.isEmpty {
            ContentStatusView(.loading("リアルタイム配信を読み込み中"))
        } else if let presentation = viewModel.errorPresentation, viewModel.channels.isEmpty {
            ContentStatusView(
                .failure(
                    title: presentation.title,
                    message: "\(presentation.message)\n\(presentation.recoverySuggestion)"
                ),
                retryTitle: "再試行",
                retry: { Task { await viewModel.refresh() } }
            )
        } else if viewModel.channels.isEmpty {
            ContentStatusView(
                .empty(
                    title: "配信中のチャンネルがありません",
                    message: "時間をおいて、もう一度更新してください。",
                    systemImage: "tv.slash"
                ),
                retryTitle: "更新",
                retry: { Task { await viewModel.refresh() } }
            )
        } else {
            channelList
        }
    }

    private var channelList: some View {
        List {
            Section { availabilityNotice }
            Section {
                ForEach(viewModel.channels) { channel in
                    row(for: channel)
                }
            } header: {
                SectionHeader(
                    "チャンネル",
                    subtitle: "\(viewModel.playableChannelCount)/\(viewModel.channels.count) が今すぐ見られます"
                )
            }
        }
        .listStyle(.plain)
        .refreshable { await viewModel.refresh() }
        .overlay(alignment: .top) { refreshIndicator }
    }

    /// 再生を試す前に、このエリアで何が見られるのかを先に出す。
    private var availabilityNotice: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Label(TVerAreaAvailability.headline(for: areaStore.selected), systemImage: "info.circle")
                .font(.footnote.weight(.semibold))
            Text(TVerAreaAvailability.detail(for: areaStore.selected))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, DS.Spacing.xs)
        .listRowSeparator(.hidden)
        .accessibilityElement(children: .combine)
    }

    private func row(for channel: TVerLiveChannel) -> some View {
        Button {
            DiagnosticLogStore.shared.record(
                .info,
                category: "playback",
                message: "Live playback selected"
            )
            selectedChannel = channel
        } label: {
            MediaRow(
                title: channel.currentProgram?.seriesTitle ?? channel.name,
                subtitle: subtitle(for: channel),
                detail: detail(for: channel),
                thumbnailURL: channel.currentProgram?.thumbnailURL ?? channel.iconURL,
                badges: badges(for: channel)
            ) {
                Image(systemName: channel.isPlayable ? "play.circle.fill" : "nosign")
                    .font(.title3)
                    .foregroundStyle(channel.isPlayable ? DS.Palette.live : Color.secondary)
                    .frame(width: DS.Size.minimumTapTarget, height: DS.Size.minimumTapTarget)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.plain)
        .disabled(!channel.isPlayable)
        .opacity(channel.isPlayable ? 1 : 0.45)
        .listRowInsets(EdgeInsets(top: 0, leading: DS.Spacing.l, bottom: 0, trailing: DS.Spacing.l))
        .accessibilityLabel(TVerAccessibilityText.live(channel: channel))
        .accessibilityHint(channel.isPlayable ? "ダブルタップしてライブを視聴します" : "現在は視聴できません")
        .contextMenu { rowMenu(for: channel) }
    }

    @ViewBuilder
    private func rowMenu(for channel: TVerLiveChannel) -> some View {
        let shareItem = ProgramShareItem(channel: channel)
        ShareLink(
            item: shareItem.url,
            subject: Text(shareItem.subject),
            message: Text(shareItem.message)
        ) {
            Label("共有", systemImage: "square.and.arrow.up")
        }
        Button {
            openURL(channel.webURL)
        } label: {
            Label("TVer公式ページで開く", systemImage: "safari")
        }
    }

    /// いまどのエリアを見ているのかを常に出し、その場で切り替えられるようにする。
    private var areaPicker: some View {
        Menu {
            ForEach(areaStore.groupedAreas) { group in
                Section(group.name) {
                    ForEach(group.areas) { area in
                        Button {
                            switchArea(to: area)
                        } label: {
                            if area.code == areaStore.selected.code {
                                Label(area.name, systemImage: "checkmark")
                            } else {
                                Text(area.name)
                            }
                        }
                    }
                }
            }
        } label: {
            Label(areaStore.selected.name, systemImage: "mappin.and.ellipse")
                .labelStyle(.titleAndIcon)
                .font(.subheadline.weight(.semibold))
                .frame(minWidth: DS.Size.minimumTapTarget, minHeight: DS.Size.minimumTapTarget)
        }
        .disabled(areaStore.isSwitchingArea || !viewModel.supportsAreaSwitching)
        .accessibilityLabel("エリアを選択")
        .accessibilityValue(areaStore.selected.name)
        .accessibilityHint("いま表示しているエリアです。ダブルタップして他のエリアに切り替えられます")
    }

    /// エリアを切り替えて一覧を取り直す。取得に失敗したら `AreaStore` が選択を元に戻す。
    private func switchArea(to area: TVerArea) {
        Task {
            await areaStore.select(area) { target in
                await viewModel.load(area: target)
            }
        }
    }

    @ViewBuilder
    private var refreshIndicator: some View {
        if viewModel.isLoading, !viewModel.channels.isEmpty {
            ProgressView()
                .padding(DS.Spacing.s)
                .background(.regularMaterial, in: Circle())
                .padding(.top, DS.Spacing.s)
                .accessibilityLabel(areaStore.isSwitchingArea ? "エリアを切り替え中" : "更新中")
        }
    }

    /// 再生できない行は、その理由を番組名より先に見せる。
    private func subtitle(for channel: TVerLiveChannel) -> String {
        if let caution = TVerAreaAvailability.rowCaution(for: channel) { return caution }
        return channel.currentProgram?.title ?? "番組情報を取得できませんでした"
    }

    private func detail(for channel: TVerLiveChannel) -> String {
        var parts = [channel.name]
        if let program = channel.currentProgram {
            parts.append(program.timeLabel)
        }
        return parts.joined(separator: "・")
    }

    private func badges(for channel: TVerLiveChannel) -> [MediaBadge] {
        switch channel.state {
        case .onAir: return [MediaBadge(.live)]
        case .paused: return [MediaBadge(.catchUpChecking, text: "配信休止")]
        case .unavailable: return [MediaBadge(.noCatchUp, text: "配信なし")]
        }
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
                        Label(Vocabulary.Live.onAir, systemImage: "dot.radiowaves.left.and.right")
                            .font(.caption.bold()).foregroundStyle(.red)
                        Text(channel.currentProgram?.seriesTitle ?? "TVer リアルタイム配信").font(.title2.bold())
                        Text(channel.currentProgram?.title ?? channel.name).foregroundStyle(.secondary)
                        if let program = channel.currentProgram {
                            Label(program.timeLabel, systemImage: "clock").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }

                    playbackStatus

                    dismissalNotice

                    PictureInPictureControl(coordinator: pictureInPicture)

                    ShareLink(item: shareItem.url, subject: Text(shareItem.subject), message: Text(shareItem.message)) {
                        Label("このライブ配信を共有", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity, minHeight: DS.Size.minimumTapTarget)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    if !(isCurrent && playbackController.errorPresentation != nil) {
                        Button { openURL(channel.webURL) } label: {
                            Label("TVer公式ライブページで開く", systemImage: "safari")
                                .frame(maxWidth: .infinity, minHeight: DS.Size.minimumTapTarget)
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
                // iOS 16 では `.topBarTrailing` が無いので、契約の ToolbarCompat に寄せる。
                ToolbarItem(placement: ToolbarCompat.leading) {
                    Button(role: .destructive) {
                        playbackController.stop()
                        dismiss()
                    } label: {
                        Text("停止")
                            .frame(minWidth: DS.Size.minimumTapTarget, minHeight: DS.Size.minimumTapTarget)
                    }
                    .disabled(!isCurrent)
                    .accessibilityLabel("再生を停止して閉じる")
                    .accessibilityHint("映像も音声も止まります")
                }
                ToolbarItem(placement: ToolbarCompat.trailing) {
                    // 「閉じる」だけだと停止と見間違えられる。再生が続くことを文言で言う。
                    Button {
                        dismiss()
                    } label: {
                        Text("再生したまま閉じる")
                            .frame(minWidth: DS.Size.minimumTapTarget, minHeight: DS.Size.minimumTapTarget)
                    }
                    .accessibilityLabel("再生したままこの画面を閉じる")
                    .accessibilityHint("再生は続きます。画面下のバーから一時停止と停止ができます")
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

    /// 閉じたあとに音だけ鳴り続けているように見えないよう、どこで止められるのかを先に言う。
    @ViewBuilder
    private var dismissalNotice: some View {
        if isCurrent, playbackController.errorPresentation == nil {
            Label(
                "「再生したまま閉じる」を押しても配信は続きます。停止は画面下の再生バーか、この画面左上の「停止」から。",
                systemImage: "info.circle"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
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
                .frame(minHeight: DS.Size.minimumTapTarget)
                .accessibilityLabel("ライブ配信を準備中")
        } else {
            Button { playbackController.togglePlayback() } label: {
                Label(
                    playbackController.isPlaying ? "一時停止" : "再生",
                    systemImage: playbackController.isPlaying ? "pause.fill" : "play.fill"
                )
                .frame(maxWidth: .infinity, minHeight: DS.Size.minimumTapTarget)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
        }
    }
}
