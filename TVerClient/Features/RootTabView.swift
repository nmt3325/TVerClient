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
        TabView {
            ProgramGuideView(
                viewModel: ProgramGuideViewModel(service: TVerAPIClient()),
                playbackController: playbackController,
                libraryStore: libraryStore
            )
            .tabItem {
                Label("番組表", systemImage: "rectangle.grid.3x2")
            }

            ScheduleView(
                viewModel: ScheduleViewModel(service: TVerAPIClient()),
                playbackController: playbackController,
                libraryStore: libraryStore
            )
            .tabItem {
                Label("見逃し", systemImage: "play.rectangle.on.rectangle")
            }

            LibraryView(
                libraryStore: libraryStore,
                playbackController: playbackController
            )
            .tabItem {
                Label("ライブラリ", systemImage: "books.vertical")
            }

            LiveView(
                viewModel: LiveViewModel(service: TVerAPIClient()),
                playbackController: playbackController
            )
            .tabItem {
                Label("ライブ", systemImage: "dot.radiowaves.left.and.right")
            }

            DiagnosticsView(logStore: diagnosticLogStore)
                .tabItem {
                    Label("診断", systemImage: "stethoscope")
                }
        }
        .tint(.blue)
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
