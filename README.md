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
| M2 | HTTPサーバーと `POST /capture` | 完了(build 2 で実機の撮影を確認) |
| M3 | `/stream`(MJPEG)とWeb操作画面 | 完了(build 3 で実機のライブ映像を確認) |
| M4 | カメラ切替・フラッシュ・タップでピント・写真アプリ保存・自動化スクリプト | 完了(build 4 で実機を確認) |
| 追加 | PCの保存先フォルダーをページから選んで自動保存 | コード作成済み・実機未確認(保存の流れは模擬サーバーで確認) |

## 構成

```
project.yml                     XcodeGenの定義(Xcodeプロジェクトと Info.plist はCI上で生成)
RemoteShutter/
  RemoteShutterApp.swift        アプリの入口とiPhoneの画面
  AppModel.swift                状態管理、ログ、HTTPのルーティングと認証
  CameraController.swift        AVCaptureSession、フル解像度JPEGの撮影、向き・カメラ切替・フラッシュ・ピント
  PhotoLibrary.swift            iPhoneの写真アプリへの保存
  LiveStream.swift              ライブ映像を低解像度JPEGにしてMJPEGで配信
  HTTPServer.swift              NWListener による最小HTTPサーバー(通常の応答とストリーム)
  WebPage.swift                 PCのブラウザに返す操作ページ
  NetworkInfo.swift             Wi-FiのIPアドレス取得
tools/capture.ps1               PCから撮影して保存するスクリプト(連続・一定間隔の撮影も)
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

## 4. 使い方

1. iPhoneとPCを**同じWi-Fi**につなぐ
2. iPhoneでアプリを開く。初回は「カメラ」と「ローカルネットワーク」の許可を求められるので、両方とも許可する
3. 画面に出る `http://<IP>:8080/?token=<トークン>` を、PCのブラウザで開く
4. 左にライブ映像が出る。「撮影」ボタン(またはSpaceキー)でフル画質の写真を撮る
5. 撮った写真は右の一覧に並ぶ(最新12枚)。サムネイルで拡大表示、「保存」でダウンロード。「撮ったら自動で保存」にチェックすると毎回ダウンロードされる
6. iPhoneを横向きで三脚に付けるときは、「向き」を合わせる(写真とライブ映像の両方に効く。iPhoneの画面からも変えられる)
7. ライブ映像を**クリックするとその位置にピントと明るさを合わせる**。ダブルクリックで自動に戻る(構図が大きく変わったときも自動に戻る)
8. 右の設定で、カメラ(背面/前面)、フラッシュ(オフ/自動/オン)、「iPhoneの写真アプリにも保存」を切り替えられる。設定はiPhoneに記憶される
   - 前面カメラのライブ映像は鏡のように左右反転して表示する(撮った写真は反転しない)
   - 「写真アプリにも保存」を初めてオンにすると、iPhoneに許可を求めるダイアログが出るので「許可」する

アプリは**前面に開いたまま**にしておく(ホーム画面に戻ったり画面を消したりすると止まる)。

### PCの保存先フォルダーを決めて自動保存する

ページの「PC の保存先フォルダー」で「フォルダーを選ぶ」を押してフォルダーを選ぶと、以後撮った写真はそのフォルダーに自動で保存される(「撮ったら PC に自動で保存」もオンになる)。選んだフォルダーはブラウザが覚えているので、ページを開き直しても同じフォルダーに保存される。「解除」でブラウザのダウンロード先に戻る。

ブラウザは、`http://` のページにはこの機能を使わせないので、**最初に1回だけ**ブラウザの設定が必要(Chrome・Edge・Vivaldi などChromium系のみ。Firefoxは非対応)。

1. 新しいタブのアドレス欄に `vivaldi://flags/#unsafely-treat-insecure-origin-as-secure` を入れて開く(Chromeは `chrome://`、Edgeは `edge://` で始める)
2. 「Insecure origins treated as secure」の欄に、iPhoneのページのアドレス(例: `http://192.168.1.23:8080`)を入れ、右の選択を **Enabled** にする。ページの「フォルダーを選べるようにする」を開くと、入れるアドレスとコピーボタンが出る
3. 「Relaunch」でブラウザを再起動し、ページを開き直す

注意:

- iPhoneのIPアドレスが変わると、上の設定とフォルダーの選択をやり直す必要がある。ルーターの設定で iPhone に固定のIPアドレスを割り当てておくと楽
- ブラウザを開き直したあとの最初の撮影で、「このフォルダーへの書き込みを許可しますか」と聞かれることがある。許可すれば保存が続く(「毎回許可」を選べば次から聞かれない)

### PCのスクリプトで撮る(連続撮影・タイムラプス)

`tools/capture.ps1` を使う。`-Url` には iPhone の画面に出ている URL をそのまま貼る。写真は既定で「ピクチャ\RemoteShutter」に保存される。

1枚撮る:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\capture.ps1 -Url "http://<IP>:8080/?token=<トークン>"
```

10秒ごとに60枚撮って D:\timelapse に保存する:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\capture.ps1 -Url "http://<IP>:8080/?token=<トークン>" -Count 60 -IntervalSec 10 -OutDir D:\timelapse
```

| オプション | 内容 |
|---|---|
| `-Count` | 撮る枚数(既定 1) |
| `-IntervalSec` | 撮影の間隔(秒)。撮影にかかった時間を含めて数える |
| `-OutDir` | 保存先フォルダー |
| `-Camera back\|front` | 撮る前にカメラを切り替える |
| `-Flash off\|auto\|on` | 撮る前にフラッシュを設定する |
| `-Orientation portrait\|landscapeRight\|landscapeLeft\|portraitUpsideDown` | 撮る前に向きを設定する |

`-ExecutionPolicy Bypass` は、このスクリプトを実行するときだけ PowerShell の実行制限を外す指定(PCの設定は変わらない)。

### curl で撮る

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
| GET | `/stream` | ライブ映像(MJPEG、横幅最大960px・最大15fps) |
| POST | `/settings?...` | 設定を変える(指定したものだけ)。`orientation=portrait\|landscapeRight\|landscapeLeft\|portraitUpsideDown`、`camera=back\|front`、`flash=off\|auto\|on`、`saveToPhotos=1\|0` |
| POST | `/focus?x=0.5&y=0.5` | ライブ映像上の位置(左上0,0〜右下1,1)にピントと明るさを合わせる。`/focus?reset=1` で自動に戻す |
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
