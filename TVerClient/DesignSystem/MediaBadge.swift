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

    /// 文言は画面ごとに持たず、契約の `Vocabulary` に寄せる。
    /// 同じ状態を「見逃し」「キャッチアップ」「保存済み」と呼び分けないため。
    var defaultText: String {
        switch self {
        case .live: return Vocabulary.Live.onAir
        case .catchUp: return Vocabulary.CatchUp.available
        case .catchUpChecking: return Vocabulary.CatchUp.checking
        case .noCatchUp: return Vocabulary.CatchUp.none
        case .downloaded: return Vocabulary.Download.completed
        case .downloading: return Vocabulary.Download.running
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
        // 強弱を色の濃さだけではなく、塗りつぶしと線の違いでも表す。
        // 色覚異常やグレースケール表示でも区別が残るようにするため。
        .overlay(
            Capsule()
                .strokeBorder(kind.tint.opacity(kind.isLowEmphasis ? 0.45 : 0), lineWidth: 1)
        )
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
