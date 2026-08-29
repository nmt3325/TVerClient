# TVerClient

TVerClient は、SwiftUI で実装している非公式の iOS クライアントです。TVer の番組情報を扱い、アプリ内での閲覧・再生につなげるための基盤を整備しています。

> [!IMPORTANT]
> 現在は開発初期段階です。画面や API クライアントには未実装部分があり、日常利用できる完成版ではありません。


## LiveContainerでの診断ログ

アプリ下部の「診断」タブから通信診断を実行し、「ログを書き出す」でテキストファイルを保存・共有できます。LiveContainerで番組取得や再生に失敗する場合は、問題を再現した直後に書き出してください。ログにはOS・アプリバージョン、TVer/Streaksへの疎通結果、番組表取得・再生の失敗段階が含まれます。トークン、Cookie、リクエストヘッダー、URLクエリ、実際の配信URLは記録されません。

## 現在の機能

- SwiftUI / `NavigationStack` を使ったアプリシェル
- 番組・配信日のデータモデル
- TVer のエピソード URL 生成
- 「ライブ」タブで公式リアルタイム配信5局の現在番組・放送時刻・配信状態を表示
- 公式 Streaks HLS が利用可能な場合の `AVPlayer` ライブ再生
- ライブ直接再生が利用できない場合のTVer公式ライブページへの明示的フォールバック
- `AVPlayer`、Now Playing、Remote Command、バックグラウンド音声を共用する再生コントローラー
- カタログ取得・ストリーム解決を差し替えられるプロトコル境界
- XCTest によるモデルの単体テスト
- GitHub Actions とローカルスクリプトによる unsigned IPA の生成

## 要件

- macOS
- Xcode 16 以降
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- iOS 16.0 以降

```bash
brew install xcodegen
```

## ローカルビルド

Xcode プロジェクトは `project.yml` から生成します。

```bash
git clone <repository-url>
cd TVerClient
xcodegen generate
open TVerClient.xcodeproj
```

コマンドラインで Simulator 向けにビルドする場合:

```bash
xcodebuild \
  -project TVerClient.xcodeproj \
  -scheme TVerClient \
  -destination 'generic/platform=iOS Simulator' \
  build
```

テストは Xcode で実行するか、利用可能な Simulator を指定して実行してください。

```bash
xcodebuild \
  -project TVerClient.xcodeproj \
  -scheme TVerClient \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  test
```

## unsigned IPA の作成

署名なしのデバイス向け Release ビルドを `Payload/TVerClient.app` 構造にまとめます。

```bash
xcodegen generate
./scripts/build-unsigned-ipa.sh
```

出力先と DerivedData は変更できます。

```bash
./scripts/build-unsigned-ipa.sh \
  --derived-data /tmp/TVerClient-DerivedData \
  --output ./TVerClient-unsigned.ipa
```

この IPA 自体には署名がないため、そのまま端末へインストールできません。

## GitHub Actions から IPA を取得する

1. GitHub の **Actions** タブで `Build unsigned IPA` を開きます。
2. `main` への push、Pull Request、または手動実行の完了を待ちます。
3. 実行結果の **Artifacts** から `TVerClient-unsigned` をダウンロードします。
4. `main` への push と手動実行では、同じ IPA が最新の GitHub Release にも添付されます。

## AltStore・SideStore・LiveContainerソース

ソースページ: <https://nmt3325.github.io/TVerClient/>

ソースURL:

```text
https://nmt3325.github.io/TVerClient/apps.json
```

ページの「AltStore / SideStoreに追加」または「LiveContainerに追加」から登録できます。各成功ビルドで、最新版Unsigned IPAのバージョン・ファイルサイズ・ダウンロードURLを含むソースJSONを自動生成します。

## SideStore などで署名して導入する

1. GitHub Actions またはローカルビルドから `TVerClient-unsigned.ipa` を取得します。
2. SideStore、AltStore、Sideloadly など、自分の Apple ID で IPA を署名できるツールへ読み込みます。
3. ツールの案内に従って署名し、登録した iPhone / iPad へインストールします。
4. 無料の Apple ID を使う場合は、署名の有効期限や同時に導入できる App 数の制限に従って再署名します。

端末・OS・署名ツールの組み合わせによって手順は異なります。各ツールの公式ドキュメントも確認してください。

## アーキテクチャ

```text
TVerClient/
├── App/          # アプリのエントリーポイント
├── Contracts/    # モデル、エラー、サービス境界
├── Features/     # SwiftUI の画面・機能
├── Playback/     # AVPlayer を使う再生状態管理
├── Services/     # TVer API との通信実装
└── Resources/    # Asset Catalog
```

- **UI**: SwiftUI
- **状態管理**: `ObservableObject` と `@Published`
- **再生**: AVFoundation / `AVPlayer`
- **プロジェクト生成**: XcodeGen
- **CI**: GitHub Actions（Simulator テスト、署名なし device build、IPA 配布）

## ライブ配信について

局一覧・タイムライン・ストリーム解決には、TVerがWeb向けに提供している公式APIと公式HTTPS配信URLだけを使用します。固定IPTV URLや第三者の再配信URLは使用しません。公式メタデータがAVPlayer互換のクリアHLSを公開しない場合やアクセス条件を満たさない場合は、アプリ内再生を行わず「TVer公式ライブページで開く」ボタンを案内します。

## 既知の制約

- TVer 側のAPI・配信方式・地域・時刻・アクセス条件の変更により、一覧取得または直接再生が利用できなくなる可能性があります。
- DRM、SSAI、広告SDKなど専用の再生処理が必要なライブは、通常の `AVPlayer` URLとして直接再生せず公式ページへフォールバックします。
- ライブはシーク非対応です。Remote Commandの再生・一時停止は利用できますが、再生位置変更は無効になります。
- バックグラウンドでは音声のみ継続します。iOSの設定やシステム判断により停止する場合があります。
- GitHub で配布する IPA は unsigned であり、利用者自身による署名が必要です。

## ライセンスと利用上の注意

本リポジトリのソースコードは [MIT License](LICENSE) で提供されます。ただし、MIT License が許諾するのは本リポジトリのコードのみです。TVer の非公開・公開 API、映像・音声・画像・番組情報などのメディア、ロゴおよび商標に対する利用許諾を与えるものではありません。

本プロジェクトは TVer 公式アプリではなく、TVer または関連各社との提携・承認を示すものではありません。利用者は、TVer および権利者が定める利用規約、地域制限、認証・アクセス条件、適用法令を確認し、遵守する責任があります。アクセス制限や地域制限の回避を目的として使用しないでください。
