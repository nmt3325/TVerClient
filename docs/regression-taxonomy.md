# 回帰の3分類 (0.1.0 - 0.1.3)

0.2 の投資先を決めるために、これまでの修正コミットを原因で分類した。
分類は `EndpointFailureCategory` と対応する。

| コミット | 内容 | 分類 |
| --- | --- | --- |
| 3329a87 | 公式 snake_case id を読めずライブ再生が壊れた | clientBug |
| 47716da | VOD ストリーム解決が不安定 | clientBug |
| c945153 | ライブ SSAI セッションの流れ修正 | clientBug |
| 537ce2e | Picture in Picture コントローラの unwrap 漏れ | clientBug |
| c623b72 | LiveContainer で再生がフリーズ | environment |
| 08a30bd | iOS 18 で PiP テストがコンパイルできない | environment |
| 2fbabb2 | 並列統合時のコンパイルエラー | process |

## 読み取れること

- 実測された `upstreamChange` は 0 件。壊れた原因のほとんどは自分の実装漏れ (clientBug)。
- 次に多いのが実行環境差 (environment)。LiveContainer と Simulator の差はテストで再現できない。
- したがって 0.2 の投資は、スキーマ変更への深い抽象化ではなく
  **実応答の形を固定した fixture による自傷防止**を最優先にする。
- 抽象化の深さは、fixture 変異 (mutation) テストで測れる範囲までに留める。

## 未確定

- 上流の変更頻度は未計測。yt-dlp の TVer extractor の差分を追うことで間接的に観測する。
- LiveContainer フリーズの根本原因は未特定。現状の修正は対症療法の可能性がある。
