import SwiftUI

/// Why a row or guide block is marked.
enum MediaBadgeKind: String, Equatable, Hashable, Sendable {
    case live
    case catchUp
    case catchUpChecking
    case noCatchUp
    case downloaded
    case downloading
    case expiringSoon

    var defaultText: String {
        switch self {
        case .live: return "配信中"
        case .catchUp: return "見逃し"
        case .catchUpChecking: return "確認中"
        case .noCatchUp: return "見逃しなし"
        case .downloaded: return "保存済み"
        case .downloading: return "保存中"
        case .expiringSoon: return "まもなく終了"
        }
    }

    var systemImage: String {
        switch self {
        case .live: return "dot.radiowaves.left.and.right"
        case .catchUp: return "play.rectangle.fill"
        case .catchUpChecking: return "ellipsis.circle"
        case .noCatchUp: return "nosign"
        case .downloaded: return "arrow.down.circle.fill"
        case .downloading: return "arrow.down.circle"
        case .expiringSoon: return "clock.badge.exclamationmark"
        }
    }

    var tint: Color {
        switch self {
        case .live: return DS.Palette.live
        case .catchUp: return DS.Palette.catchUp
        case .catchUpChecking: return DS.Palette.inactive
        case .noCatchUp: return DS.Palette.inactive
        case .downloaded: return DS.Palette.downloaded
        case .downloading: return DS.Palette.catchUp
        case .expiringSoon: return DS.Palette.warning
        }
    }

    /// Muted states stay readable without competing with the real status pills.
    var isLowEmphasis: Bool {
        self == .catchUpChecking || self == .noCatchUp
    }
}

/// Compact status pill used by lists and the program guide.
struct MediaBadge: View, Equatable, Hashable {
    let kind: MediaBadgeKind
    var text: String?

    init(_ kind: MediaBadgeKind, text: String? = nil) {
        self.kind = kind
        self.text = text
    }

    var label: String { text ?? kind.defaultText }

    var body: some View {
        HStack(spacing: DS.Spacing.xxs) {
            Image(systemName: kind.systemImage)
                .imageScale(.small)
                .symbolRenderingMode(.hierarchical)
            Text(label)
                .lineLimit(1)
        }
        .font(DS.Typography.badge)
        .padding(.horizontal, DS.Spacing.s)
        .padding(.vertical, DS.Spacing.xxs)
        .foregroundStyle(kind.tint)
        .background(kind.tint.opacity(kind.isLowEmphasis ? 0.10 : 0.14), in: Capsule())
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(label)
    }

    static func == (lhs: MediaBadge, rhs: MediaBadge) -> Bool {
        lhs.kind == rhs.kind && lhs.text == rhs.text
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
        hasher.combine(text)
    }
}
