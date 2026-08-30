import Foundation

/// One entry of the subtitle or audio track menu.
struct MediaSelectionEntry: Identifiable, Equatable, Hashable {
    /// Identifier of the "subtitles off" entry.
    static let offIdentifier = "off"

    let id: String
    let title: String
    var isSelected: Bool = false
}
