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
    @State private var path: [TVerLiveChannel] = []
    @EnvironmentObject private var areaStore: AreaStore
    @EnvironmentObject private var tabReselection: TabReselection
    @Environment(\.openURL) private var openURL

    init(viewModel: LiveViewModel, playbackController: PlaybackController) {
        _viewModel = StateObject(wrappedValue: viewModel)
        self.playbackController = playbackController
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .safeAreaInset(edge: .top, spacing: 0) { notices }
                .navigationTitle("ライブ")
                // 行を押したら push で開く。シートだと戻り方が二通りになり、
                // 再生を続けたまま戻る操作が標準の戻るボタンとぶつかる。
                .navigationDestination(for: TVerLiveChannel.self) { channel in
                    LivePlaybackView(channel: channel, playbackController: playbackController)
                }
                .toolbar {
                    ToolbarItem(placement: ToolbarCompat.leading) { refreshIndicator }
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
        .onPlayerPresentationRequest(playbackController.presentationRequestToken) {
            // ミニプレイヤーからの戻り。再生中のチャンネルを push し直す。
            guard let channel = playbackController.currentLiveChannel else { return }
            if path.last != channel {
                path = [channel]
            }
        }
    }

    /// 一覧の上に常設する告知。古い一覧を見ていることと、エリア切替の失敗を黙らせない。
    ///
    /// 常設帯はこの `.safeAreaInset(edge: .top)` 一本に集める。リストの中や
    /// overlay に散らすと、スクロールで隠れたり二重に出たりする。
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

    /// 見た目は `FreshnessBanner` と同じ標準素材に揃える。自前の色地ではなく
    /// ナビゲーションバーと同じ `.bar` + 下辺の Divider にする。
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
            Button("閉じる") { areaStore.clearAreaSwitchFailure() }
                .font(.footnote.weight(.semibold))
                .frame(minWidth: DS.Size.minimumTapTarget, minHeight: DS.Size.minimumTapTarget)
                .accessibilityLabel("エリア切替のお知らせを閉じる")
        }
        .padding(.horizontal, DS.Spacing.l)
        .padding(.vertical, DS.Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
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
                    message: "\\(presentation.message)\\n\\(presentation.recoverySuggestion)"
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
        ScrollViewReader { proxy in
            List {
                Section {
                    Label(
                        TVerAreaAvailability.headline(for: areaStore.selected),
                        systemImage: "info.circle"
                    )
                    .font(.footnote)
                    .id(StandardScrollAnchor.top)
                } footer: {
                    Text(TVerAreaAvailability.detail(for: areaStore.selected))
                }

                Section {
                    ForEach(viewModel.channels) { channel in
                        row(for: channel)
                    }
                } header: {
                    Text("チャンネル")
                } footer: {
                    Text("\\(viewModel.playableChannelCount)/\\(viewModel.channels.count) が今すぐ見られます")
                }
            }
            .listStyle(.plain)
            .refreshable { await viewModel.refresh() }
            // 表示中のタブをもう一度押したら先頭へ戻す。標準アプリと同じ操作。
            .onReceive(tabReselection.events) { tab in
                guard tab == .live else { return }
                withAnimation { proxy.scrollTo(StandardScrollAnchor.top, anchor: .top) }
            }
        }
    }

    private func row(for channel: TVerLiveChannel) -> some View {
        NavigationLink(value: channel) {
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
                    .accessibilityHidden(true)
            }
        }
        // 減光は `.disabled` の標準表現に任せる。自前の `.opacity` は二重に薄くなる。
        .disabled(!channel.isPlayable)
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
    ///
    /// 選択中の印は `Picker` に任せる。自前で checkmark を描くと、標準の
    /// 選択表現（チェックの位置と読み上げ）から外れる。
    private var areaPicker: some View {
        Menu {
            Picker("エリア", selection: areaSelection) {
                ForEach(areaStore.groupedAreas) { group in
                    Section(group.name) {
                        ForEach(group.areas) { area in
                            Text(area.name).tag(area.code)
                        }
                    }
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(areaStore.selected.name, systemImage: "mappin.and.ellipse")
                .labelStyle(.titleAndIcon)
        }
        .disabled(areaStore.isSwitchingArea || !viewModel.supportsAreaSwitching)
        .accessibilityLabel("エリアを選択")
        .accessibilityValue(areaStore.selected.name)
        .accessibilityHint("いま表示しているエリアです。ダブルタップして他のエリアに切り替えられます")
    }

    /// `AreaStore.select(_:reload:)` は「選ぶ→取り直す→失敗したら巻き戻す」副作用付き。
    /// `$areaStore.selected` を直結すると取り直しも巻き戻しも走らないので、
    /// 書き込みを差し替えた Binding を Picker に渡す。
    private var areaSelection: Binding<String> {
        Binding(
            get: { areaStore.selected.code },
            set: { newCode in
                guard newCode != areaStore.selected.code,
                      let area = areaStore.groupedAreas
                          .flatMap({ $0.areas })
                          .first(where: { $0.code == newCode })
                else { return }
                switchArea(to: area)
            }
        )
    }

    /// エリアを切り替えて一覧を取り直す。取得に失敗したら `AreaStore` が選択を元に戻す。
    private func switchArea(to area: TVerArea) {
        Task {
            await areaStore.select(area) { target in
                await viewModel.load(area: target)
            }
        }
    }

    /// 引き下げ更新の輪は `.refreshable` が出すので、ここでは出さない。
    /// エリア切替のようにリストの外から始まる更新だけ、ツールバーで小さく知らせる。
    @ViewBuilder
    private var refreshIndicator: some View {
        if viewModel.isLoading, !viewModel.channels.isEmpty {
            ProgressView()
                .controlSize(.small)
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

/// ライブ詳細。一覧から push で開く。
///
/// 以前は `ScrollView` + `VStack` + 自前 padding の縦積みで、映像も見逃し側と
/// 別実装だった。標準の `List`（insetGrouped）+ `Section` + `LabeledContent` に寄せ、
/// 映像は見逃しと同じ `PlayerStage` に一本化する。
@MainActor
struct LivePlaybackView: View {
    let channel: TVerLiveChannel
    @ObservedObject var playbackController: PlaybackController
    @StateObject private var pictureInPicture = PictureInPictureCoordinator()
    @StateObject private var chrome = PlayerChromeModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var isFullScreenPresented = false

    private var shareItem: ProgramShareItem { ProgramShareItem(channel: channel) }
    private var isCurrent: Bool { playbackController.currentLiveChannel?.id == channel.id }

    var body: some View {
        List {
            Section {
                stage
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.black)
                playbackStatus
            } footer: {
                dismissalNotice
            }

            Section("番組") {
                LabeledContent("チャンネル") { Text(channel.name) }
                LabeledContent("番組") {
                    Text(channel.currentProgram?.seriesTitle ?? "TVer リアルタイム配信")
                        .multilineTextAlignment(.trailing)
                }
                if let program = channel.currentProgram {
                    LabeledContent("サブタイトル") {
                        Text(program.title)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("放送時間") { Text(program.timeLabel) }
                }
                LabeledContent("状態") {
                    Label(
                        stateLabel,
                        systemImage: channel.isPlayable ? "dot.radiowaves.left.and.right" : "pause.circle"
                    )
                    .foregroundStyle(channel.isPlayable ? DS.Palette.live : Color.secondary)
                }
            }

            Section {
                ShareLink(
                    item: shareItem.url,
                    subject: Text(shareItem.subject),
                    message: Text(shareItem.message)
                ) {
                    Label("このライブ配信を共有", systemImage: "square.and.arrow.up")
                }
                if !(isCurrent && playbackController.errorPresentation != nil) {
                    Button {
                        openURL(channel.webURL)
                    } label: {
                        Label("TVer公式ライブページで開く", systemImage: "safari")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(channel.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // iOS 16 では `.topBarTrailing` が無いので、契約の ToolbarCompat に寄せる。
            // 「再生したまま閉じる」は標準の戻るボタンが担うので置かない。
            ToolbarItem(placement: ToolbarCompat.trailing) {
                Button(role: .destructive) {
                    playbackController.stop()
                    dismiss()
                } label: {
                    Text("停止")
                }
                .disabled(!isCurrent)
                .accessibilityLabel("再生を停止して閉じる")
                .accessibilityHint("映像も音声も止まります")
            }
        }
        .onAppear {
            // 停止したときに小窓だけが生き残らないよう、この画面が持っている
            // Picture in Picture の調整役を再生側へ預ける。見逃し側と同じ扱いにする。
            playbackController.bindPictureInPicture(pictureInPicture)
        }
        .onDisappear {
            // 画面を離れたら預けたものを返す。別の画面が預け直したあとなら何もしない。
            playbackController.unbindPictureInPicture(pictureInPicture)
        }
        .task(id: channel.id) {
            DiagnosticLogStore.shared.record(
                .info,
                category: "playback",
                message: "Live playback selected"
            )
            await playbackController.playLive(channel)
        }
        .fullScreenCover(isPresented: $isFullScreenPresented) {
            FullScreenPlaybackView(
                playbackController: playbackController,
                pictureInPicture: pictureInPicture,
                title: channel.name,
                subtitle: channel.currentProgram?.seriesTitle,
                accessibilityLabel: "\\(channel.name)の全画面ライブ動画プレイヤー",
                supportsSeeking: false,
                onExit: { isFullScreenPresented = false }
            )
        }
    }

    /// 見逃しと同じ `PlayerStage`。ライブなので早送りと巻き戻しは持たせない。
    /// PiP のボタンも PlayerStage の overlay 側にあるので、本文には置かない。
    private var stage: some View {
        PlayerStage(
            playbackController: playbackController,
            pictureInPicture: pictureInPicture,
            model: chrome,
            title: channel.name,
            subtitle: channel.currentProgram?.seriesTitle,
            accessibilityLabel: "\\(channel.name)のライブ動画プレイヤー",
            supportsSeeking: false,
            isFullScreen: false,
            isActiveSurface: !isFullScreenPresented,
            onToggleFullScreen: { isFullScreenPresented = true }
        )
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
    }

    private var stateLabel: String {
        switch channel.state {
        case .onAir: return Vocabulary.Live.onAir
        case .paused: return Vocabulary.Live.paused
        case .unavailable: return Vocabulary.Live.unknown
        }
    }

    /// 戻ったあとに音だけ鳴り続けているように見えないよう、どこで止められるのかを先に言う。
    @ViewBuilder
    private var dismissalNotice: some View {
        if isCurrent, playbackController.errorPresentation == nil {
            Text("前の画面に戻っても配信は続きます。停止は画面下の再生バーか、この画面右上の「停止」から。")
        }
    }

    @ViewBuilder
    private var playbackStatus: some View {
        if isCurrent, let presentation = playbackController.errorPresentation {
            PlaybackFailureView(presentation: presentation, officialURL: channel.webURL) {
                Task { await playbackController.playLive(channel) }
            }
        } else if isCurrent, playbackController.state == .resolving {
            ProgressView("公式配信URLを確認中")
                .frame(maxWidth: .infinity)
                .accessibilityLabel("ライブ配信を準備中")
        } else {
            Button {
                playbackController.togglePlayback()
            } label: {
                Label(
                    playbackController.isPlaying ? "一時停止" : "再生",
                    systemImage: playbackController.isPlaying ? "pause.fill" : "play.fill"
                )
            }
        }
    }
}
