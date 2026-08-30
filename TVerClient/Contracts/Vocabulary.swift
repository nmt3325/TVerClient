import Foundation

/// 画面をまたいで同じものを同じ言葉で呼ぶための一覧。
///
/// 同じ機能が「保存」「ダウンロード」「オフライン保存」の三重呼称になり、
/// 画面には「見逃しなし」・読み上げには「配信なし」と出るような不揃いを
/// 型で防ぐ。文言を変えるときはここだけを直す。
enum Vocabulary {
    enum Download {
        static let action = "ダウンロード"
        static let queued = "順番待ち"
        static let running = "ダウンロード中"
        static let paused = "一時停止中"
        static let completed = "ダウンロード済み"
        static let failed = "ダウンロードに失敗しました"
        static let cancel = "ダウンロードを中止"
        static let remove = "ダウンロードを削除"
        static let resume = "ダウンロードを再開"
    }

    enum Library {
        static let favorites = "マイリスト"
        static let history = "最近見た"
        static let downloads = "ダウンロード済み"
    }

    enum CatchUp {
        static let available = "見逃し配信あり"
        static let none = "見逃し配信なし"
        static let checking = "確認中"
        static let unknown = "未確認"
    }

    enum Live {
        static let onAir = "配信中"
        static let paused = "配信休止中"
        static let unknown = "配信情報なし"
    }
}
