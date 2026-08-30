import SwiftUI

@main
struct TVerClientApp: App {
    var body: some Scene {
        WindowGroup {
            RootTabView()
                .task {
                    DiagnosticLogStore.shared.record(
                        .info,
                        category: "lifecycle",
                        message: "Root interface appeared"
                    )
                    await StartupSelfCheck.run()
                }
        }
    }
}
