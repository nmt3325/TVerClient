import SwiftUI

/// iOS 16 でも中身が消えないツールバー配置。
///
/// `.topBarLeading` / `.topBarTrailing` は iOS 17 以降でしか使えない。
/// このプロジェクトの最小 OS は iOS 16.0 なので、直接書くと iOS 16 では
/// 番組表のズーム・チャンネル絞り込み・更新、番組詳細の閉じる、再生画面の
/// 保存と閉じるが丸ごと失われる。ツールバーは必ずこの型を経由する。
enum ToolbarCompat {
    /// ナビゲーションバー左端。
    static var leading: ToolbarItemPlacement {
        if #available(iOS 17.0, *) {
            return .topBarLeading
        }
        return .navigationBarLeading
    }

    /// ナビゲーションバー右端。
    static var trailing: ToolbarItemPlacement {
        if #available(iOS 17.0, *) {
            return .topBarTrailing
        }
        return .navigationBarTrailing
    }
}
