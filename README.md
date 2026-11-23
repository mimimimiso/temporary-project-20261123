# RemoteShutter

Windows PCのブラウザから、iPhoneのカメラのライブ映像を見ながらシャッターを切り、フル画質のJPEGをPCで受け取る自作アプリ。

- 対象: iOS 16以降(iPhone)
- 形式: JPEG
- iPhoneの写真アプリへの保存: アプリ内の設定で切り替え(M4)
- ビルド: GitHub Actions(macOS)で署名なしの `.ipa` を作る → WindowsのSideloadlyで無料Apple IDで署名してインストール

## 進捗

| マイルストーン | 内容 | 状態 |
|---|---|---|
| M1 | 空のアプリをActionsでビルドし、実機で起動する | 完了(build 1 で実機起動を確認) |
| M2 | HTTPサーバーと `POST /capture` | コード作成済み・実機未確認 |
| M3 | `/stream`(MJPEG)とWeb操作画面 | 未着手 |
| M4 | カメラ切替・フラッシュ・タップでピント・写真アプリ保存・自動化スクリプト | 未着手 |

## 構成

```
project.yml                     XcodeGenの定義(Xcodeプロジェクトと Info.plist はCI上で生成)
RemoteShutter/
  RemoteShutterApp.swift        アプリの入口とiPhoneの画面
  AppModel.swift                状態管理、ログ、HTTPのルーティングと認証
  CameraController.swift        AVCaptureSession とフル解像度JPEGの撮影
  HTTPServer.swift              NWListener による最小HTTPサーバー
  WebPage.swift                 PCのブラウザに返す操作ページ
  NetworkInfo.swift             Wi-FiのIPアドレス取得
.github/workflows/build.yml     署名なし .ipa のビルド(どのブランチへのpushでも実行)
```

## 1. GitHubにpushする(初回)

1. GitHubで **公開(Public)** の空リポジトリを作る(README等は追加しない)。例: `remote-shutter`
2. このフォルダで:

```powershell
git remote add origin https://github.com/<ユーザー名>/remote-shutter.git
git push -u origin main
```

3. リポジトリの **Actions** タブで「Build IPA」が走る(5〜10分ほど)。手動で走らせるときは「Run workflow」
4. 成功したら、その実行ページ下部の **Artifacts** から `RemoteShutter-buildN` をダウンロードして展開 → `RemoteShutter.ipa`

## 2. Windowsの準備(初回のみ)

1. **iTunes** と **iCloud** を **Apple公式サイト版**でインストールする(Microsoft Store版は不可)
   - iTunes: https://www.apple.com/jp/itunes/ の「Windows版」から、Store以外のダウンロードリンクを選ぶ
2. **Sideloadly** を https://sideloadly.io/ からインストールする
3. iPhoneをUSBでPCにつなぎ、iPhone側で「このコンピュータを信頼」を選ぶ

## 3. iPhoneに入れる

1. Sideloadlyを起動し、上の欄で接続したiPhoneを選ぶ
2. `RemoteShutter.ipa` をSideloadlyのウィンドウにドラッグ
3. 「Apple account」に **無料のApple ID** を入れて Start。2段階認証のコードを求められたら入力する
4. iPhone側:
   - **デベロッパモードをオン**: 設定 > プライバシーとセキュリティ > デベロッパモード → 再起動して有効化
     (項目が出ないときは、一度Sideloadlyでインストールを試すと出てくる)
   - **プロファイルを信頼**: 設定 > 一般 > VPNとデバイス管理 > 自分のApple ID > 信頼
5. ホーム画面の RemoteShutter を起動し、「M1: インストールと起動に成功しました」と build番号が出ればM1完了

## 4. 使い方(M2)

1. iPhoneとPCを**同じWi-Fi**につなぐ
2. iPhoneでアプリを開く。初回は「カメラ」と「ローカルネットワーク」の許可を求められるので、両方とも許可する
3. 画面に出る `http://<IP>:8080/?token=<トークン>` を、PCのブラウザで開く
4. 「撮影」ボタン(またはSpaceキー)で撮影。写真がページに表示され、「保存」でダウンロードできる

アプリは**前面に開いたまま**にしておく(ホーム画面に戻ったり画面を消したりすると止まる)。

### PowerShellから撮る

PowerShellでは `curl` が別のコマンドの別名なので、`curl.exe` と書く。

```powershell
curl.exe -X POST "http://<IP>:8080/capture?token=<トークン>" -o photo.jpg
```

状態の確認:

```powershell
curl.exe "http://<IP>:8080/status?token=<トークン>"
```

### エンドポイント

| メソッド | パス | 内容 |
|---|---|---|
| GET | `/` | 操作ページ |
| POST | `/capture` | 撮影して JPEG を返す。`X-Photo-Width` / `X-Photo-Height` / `X-Filename` ヘッダー付き |
| GET | `/status` | 状態(JSON) |
| GET | `/log` | iPhone側のログ(テキスト) |

トークンは `?token=...`、`X-Token: ...` ヘッダー、`Authorization: Bearer ...` のどれでも渡せる。

### つながらないとき

- iPhoneの設定 > RemoteShutter で「ローカルネットワーク」と「カメラ」がオンになっているか
- PCとiPhoneが同じWi-Fiか(ゲスト用Wi-Fiや「プライバシーセパレーター」がオンのルーターだと、端末同士がつながらない)
- iPhone画面のIPアドレスが変わっていないか

### 注意

- 無料Apple IDの署名は **7日で切れる**。切れたら同じ手順でSideloadlyから入れ直す(データは消えない)
- 無料Apple IDで同時に入れられる自作アプリは3個まで
- 画面のbuild番号はActionsの実行番号。どのビルドが入っているかの確認に使う
