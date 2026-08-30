# TVerClient UI/UX 修正 — 並列実装計画

監査（576件 / 致命23・高178）をもとに、**致命17クラスタ全件**と、同じファイルを
触るついでに直せる高を直す。5つのタスクはディレクトリの所有権で切ってあり、
同じファイルを2人が編集する箱所はない。

## タスク一覧

| タスク | 担当 | 所有パス | ブランチ | 状態 |
| --- | --- | --- | --- | --- |
| t1 | プレイヤーと再生継続性 | `TVerClient/Player/**`, `TVerClient/Playback/**`, `Features/PlaybackView.swift`, `Features/FullScreenPlaybackView.swift`, `Features/PlaybackSupportViews.swift` | feat/fix-t1-player | pending |
| t2 | 番組表 | `TVerClient/Guide/**`, `Features/ProgramGuideView.swift` | feat/fix-t2-guide | pending |
| t3 | ダウンロードとライブラリ | `TVerClient/Downloads/**`, `Features/LibraryView.swift`, `Services/ProgramLibraryStore.swift` | feat/fix-t3-downloads | pending |
| t4 | 通知・ライブ・エリア・診断 | `Services/ProgramNotificationScheduler.swift`, `Features/LiveView.swift`, `Features/DiagnosticsView.swift`, `TVerClient/Area/**` | feat/fix-t4-notify-live | pending |
| t5 | 見逃し一覧・検索・通信層 | `Features/ScheduleView.swift`, `Features/SharedStatusViews.swift`, `Features/ProgramSearchViewModel.swift`, `Services/TVerAPIClient.swift`, `Services/TVerResponseCache.swift`, `Services/ProgramSearchIndex.swift`, `Services/NetworkDiagnosticsService.swift`, `TVerClient/DesignSystem/**`, `TVerClient/Images/**` | feat/fix-t5-list-network | pending |

## オーケストレータ専有（全員変更禁止）

これらは先行して確定し、main にコミット済み。**読むだけ。変更しない。**

| ファイル | 役割 |
| --- | --- |
| `Contracts/ToolbarCompat.swift` | iOS 16 で壊れないツールバー配置。`.topBarLeading` の直書きは全廃止 |
| `Contracts/PlaybackPresence.swift` | 「いま鳴っているもの」の共有型と操作契約 |
| `Contracts/PlaybackPresence+Controller.swift` | `PlaybackController.presence` の契約実装。t1 のみ改善可 |
| `Contracts/LoadFreshness.swift` | 鮮度・更新失敗の共通表現 |
| `Contracts/BroadcastDay.swift` | 放送日境界と 24〜29 時表記 |
| `Contracts/Vocabulary.swift` | 語彙統一 |
| `Contracts/Models.swift` | `TVerProgram.availableUntilAt` を追加済み。期限判定は必ずこちら |
| `DesignSystem/FreshnessBanner.swift` | 一覧上部の鮮度バナー |
| `DesignSystem/PlaybackPresenceBar.swift` | タブ上の再生中バー |
| `Features/RootTabView.swift` | タブ選択保持と再生中バーのホスト |
| `TVerClient.xcodeproj/project.pbxproj` | **commit 禁止**。統合時にオーケストレータが1回だけ再生成する |

## 確定済みの共通方針

1. **ツールバー**: `ToolbarItem(placement: ToolbarCompat.leading)` / `.trailing` を使う。
2. **停止導線**: 再生を始めた画面を閉じても `PlaybackPresenceBar` が残るので、
   「閉じる」で勝手に `stop()` しない。ただし PiP も Now Playing も無い状態で
   バーも出ない経路を作らないこと。
3. **失敗の告知**: 一覧を持つ画面は `LoadFreshness` を publish し、`FreshnessBanner` を
   リストの上に置く。スピナーが消えるだけの無言の失敗を残さない。
4. **期限**: `availableUntil`（文字列）を再パースしない。`availableUntilAt` を使う。
5. **時刻**: 番組表と一覧の日付境界・時刻表記は `BroadcastDay` 経由。
6. **語彙**: 新しい文言は `Vocabulary` に合わせる。
7. **破壊的操作**: 削除・中止・一括消去は経路に関係なく確認を出す。
8. **タップ領域**: 押せるものは 44x44pt 以上。見た目だけ広げない（`contentShape`）。
9. **アクセシビリティ**: 新規・修正した操作には label と必要な trait を付ける。
10. **エラー文言**: `localizedDescription` の生出しをやめ、次の手を必ず書く。

## 検証の共有ルール（**重要**）

この macOS は **3コア**。前回、並列で `xcodebuild` を回して load average が 900 を超え、
シミュレータが起動できずテストが全滞した。

- **シミュレータテストは禁止**。テストは統合後にオーケストレータが1回だけ回す。
- `bash scripts/lint.sh` は何度でも可（grep だけなので軽い）。
- `xcodebuild build` は **必ずロックを取ってから**、自分の worktree で行う。

```bash
# ロックを取る（取れるまで1回20秒待ちで再試行）
while ! mkdir /tmp/tver-build.lock 2>/dev/null; do sleep 20; done
# … xcodebuild …
rmdir /tmp/tver-build.lock
```

各 worktree は `-derivedDataPath /tmp/dd-<タスクID>` を必ず指定する（共有すると
`build.db is locked` になる）。
