import SwiftUI

struct RootTabView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView("番組を読み込みます", systemImage: "tv")
                .navigationTitle("TVer Client")
        }
    }
}
