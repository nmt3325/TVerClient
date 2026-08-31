import AVKit
import SwiftUI
import UIKit

/// タブの識別子。選択状態を保存し、画面間の誘導を可能にするために必要。
enum RootTab: String, Hashable {
    case catchUp
    case guide
    case live
    case library
    case diagnostics
}

/// アプリの土台。
///
/// オーケストレータ契約。タブ選択の保持と、再生中バーの常設はここが持つ。
/// 各タスクは自分の画面を直すが、このファイルは変更しない。
@MainActor
struct RootTabView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var playbackController = PlaybackController()
    @StateObject private var libraryStore = ProgramLibraryStore()
    @StateObject private var diagnosticLogStore = DiagnosticLogStore.shared
    @StateObject private var downloadCenter = DownloadCenter()
    @StateObject private var seriesSubscriptions = SeriesSubscriptionStore(service: TVerAPIClient())
    @StateObject private var catchUpAvailability = CatchUpAvailabilityStore(lookup: TVerAPIClient())
    @StateObject private var areaStore = AreaStore(service: TVerAPIClient())
    @StateObject private var tabReselection = TabReselection()

    /// アプリを離れて戻ったときに、見ていたタブへ戻る。
    @SceneStorage("RootTabView.selectedTab") private var storedTab: String = RootTab.catchUp.rawValue

    private var selection: Binding<RootTab> {
        Binding(
            get: { RootTab(rawValue: storedTab) ?? .catchUp },
            set: { newValue in
                // 表示中のタブをもう一度選んだときは、iOS 標準アプリと同じく
                // 先頭へ戻る。TabView の selection だけでは検出できないのでここで見る。
                if newValue.rawValue == storedTab {
                    tabReselection.send(newValue)
                }
                storedTab = newValue.rawValue
            }
        )
    }

    var body: some View {
        TabView(selection: selection) {
            ScheduleView(
                viewModel: ScheduleViewModel(service: TVerAPIClient()),
                playbackController: playbackController,
                libraryStore: libraryStore
            )
            .tabItem {
                Label("見逃し", systemImage: "play.rectangle.on.rectangle")
            }
            .tag(RootTab.catchUp)

            ProgramGuideView(
                viewModel: ProgramGuideViewModel(service: TVerAPIClient()),
                playbackController: playbackController,
                libraryStore: libraryStore
            )
            .tabItem {
                Label("番組表", systemImage: "calendar.day.timeline.left")
            }
            .tag(RootTab.guide)

            LiveView(
                viewModel: LiveViewModel(service: TVerAPIClient()),
                playbackController: playbackController
            )
            .tabItem {
                Label("ライブ", systemImage: "dot.radiowaves.left.and.right")
            }
            .tag(RootTab.live)

            LibraryView(
                libraryStore: libraryStore,
                playbackController: playbackController
            )
            .tabItem {
                Label("ライブラリ", systemImage: "rectangle.stack")
            }
            .tag(RootTab.library)

        }
        .tint(DS.Palette.catchUp)
        .environmentObject(downloadCenter)
        .environmentObject(seriesSubscriptions)
        .environmentObject(catchUpAvailability)
        .environmentObject(areaStore)
        .environmentObject(tabReselection)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // 再生シートを閉じても、止める場所と戻る場所が必ず画面に残る。
            if let presence = playbackController.presence {
                PlaybackPresenceBar(
                    presence: presence,
                    onToggle: { playbackController.togglePlayback() },
                    onStop: { playbackController.stop() },
                    onOpen: { selection.wrappedValue = presence.isLive ? .live : .catchUp }
                )
                .transition(.move(edge: .bottom))
            }
        }
        .animation(.easeOut(duration: DS.Motion.fadeInDuration), value: playbackController.presence)
        .task {
            seriesSubscriptions.configureAutomaticDownloads(downloadCenter)
            DownloadNetworkMonitor.shared.start()
            // Download records must be restored before subscription discovery so
            // an already queued or saved episode is never enqueued a second time.
            downloadCenter.restore()
            seriesSubscriptions.restore()
            downloadCenter.refreshStorage()
            await seriesSubscriptions.refreshAll(
                downloads: downloadCenter,
                forceRefresh: false
            )
            await areaStore.refreshAreas()
        }
        .onChange(of: scenePhase) { phase in
            guard phase == .active else { return }
            Task {
                await seriesSubscriptions.refreshAll(
                    downloads: downloadCenter,
                    forceRefresh: false
                )
            }
        }
        .onReceive(DownloadNetworkMonitor.shared.$status) { status in
            Task {
                await seriesSubscriptions.networkStatusDidChange(
                    status,
                    downloads: downloadCenter
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.willTerminateNotification
        )) { _ in
            // Do not stop on ordinary backgrounding: PiP owns that transition.
            // A real application termination must synchronously release audio,
            // the current item, Now Playing state, observers, and PiP.
            playbackController.stop()
        }
    }
}
