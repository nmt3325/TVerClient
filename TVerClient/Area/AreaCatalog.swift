import Foundation

/// Broadcast areas offered in the area picker.
///
/// Scaffold written by the orchestrator. The live/area task owns this file and
/// should replace the list with the codes TVer actually accepts.
extension TVerArea {
    static let builtIn: [TVerArea] = [
        TVerArea(code: "01", name: "北海道"),
        TVerArea(code: "04", name: "宮城"),
        TVerArea(code: "23", name: "東京"),
        TVerArea(code: "15", name: "愛知"),
        TVerArea(code: "27", name: "大阪"),
        TVerArea(code: "34", name: "広島"),
        TVerArea(code: "40", name: "福岡"),
    ]
}
