# TVerClient

TVerClient は、SwiftUI で実装している非公式の iOS クライアントです。TVer の番組情報を扱い、アプリ内での閲覧・再生につなげるための基盤を整備しています。

> [!IMPORTANT]
> 現在は開発初期段階です。画面や API クライアントには未実装部分があり、日常利用できる完成版ではありません。

## 現在の機能

- SwiftUI / `NavigationStack` を使ったアプリシェル
- 番組・配信日のデータモデル
- TVer のエピソード URL 生成
- `AVPlayer` を利用する再生コントローラーの基盤
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

## 既知の制約

- 番組表 API の取得処理は現在スタブで、空の結果を返します。
- 実際のストリーム URL 解決処理は未実装です。
- TVer 側の非公開 API・配信方式・アクセス条件の変更により動作しなくなる可能性があります。
- DRM で保護されたコンテンツは通常の `AVPlayer` URL として再生できない場合があります。
- バックグラウンド再生の entitlement・オーディオセッション調整は今後の実装対象です。
- GitHub で配布する IPA は unsigned であり、利用者自身による署名が必要です。

## ライセンス

[MIT License](LICENSE)

本プロジェクトは TVer 公式アプリではなく、TVer または関連各社との提携・承認を示すものではありません。
