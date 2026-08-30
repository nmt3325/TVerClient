import AVKit
import SwiftUI

@MainActor
struct RootTabView: View {
    @StateObject private var playbackController = PlaybackController()
    @StateObject private var libraryStore = ProgramLibraryStore()
    @StateObject private var diagnosticLogStore = DiagnosticLogStore.shared
    @StateObject private var downloadCenter = DownloadCenter()
    @StateObject private var catchUpAvailability = CatchUpAvailabilityStore(lookup: TVerAPIClient())
    @StateObject private var areaStore = AreaStore(service: TVerAPIClient())

    var body: some View {
        // Ordered by how often the tabs are actually used: catch-up first,
        // then the guide, live, saved content and finally diagnostics.
        TabView {
            ScheduleView(
                viewModel: ScheduleViewModel(service: TVerAPIClient()),
                playbackController: playbackController,
                libraryStore: libraryStore
            )
            .tabItem {
                Label("見逃し", systemImage: "play.rectangle.on.rectangle")
            }

            ProgramGuideView(
                viewModel: ProgramGuideViewModel(service: TVerAPIClient()),
                playbackController: playbackController,
                libraryStore: libraryStore
            )
            .tabItem {
                Label("番組表", systemImage: "calendar.day.timeline.left")
            }

            LiveView(
                viewModel: LiveViewModel(service: TVerAPIClient()),
                playbackController: playbackController
            )
            .tabItem {
                Label("ライブ", systemImage: "dot.radiowaves.left.and.right")
            }

            LibraryView(
                libraryStore: libraryStore,
                playbackController: playbackController
            )
            .tabItem {
                Label("ライブラリ", systemImage: "arrow.down.circle")
            }

            DiagnosticsView(logStore: diagnosticLogStore)
                .tabItem {
                    Label("診断", systemImage: "stethoscope")
                }
        }
        .tint(DS.Palette.catchUp)
        .environmentObject(downloadCenter)
        .environmentObject(catchUpAvailability)
        .environmentObject(areaStore)
        .task {
            downloadCenter.restore()
            downloadCenter.refreshStorage()
            await areaStore.refreshAreas()
        }
    }
}
