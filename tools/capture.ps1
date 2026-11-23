<#
.SYNOPSIS
  RemoteShutter で撮影して、写真を PC に保存する(1枚だけ、または一定間隔で何枚も)。

.DESCRIPTION
  iPhone の RemoteShutter アプリの画面に出ている URL(http://<IP>:8080/?token=...)を -Url に渡す。
  iPhone ではアプリを前面に開いたままにしておくこと。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tools\capture.ps1 -Url "http://192.168.1.23:8080/?token=abcd2345"
  1枚撮って「ピクチャ\RemoteShutter」に保存する。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tools\capture.ps1 -Url "http://192.168.1.23:8080/?token=abcd2345" -Count 60 -IntervalSec 10 -OutDir D:\timelapse
  10秒ごとに60枚撮る(タイムラプス)。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tools\capture.ps1 -Url "..." -Flash on -Camera front
  前面カメラ・フラッシュありに切り替えてから撮る(設定は iPhone 側に残る)。
#>
param(
    [Parameter(Mandatory = $true)][string]$Url,
    [ValidateRange(1, 100000)][int]$Count = 1,
    [ValidateRange(0, 86400)][double]$IntervalSec = 0,
    [string]$OutDir = (Join-Path ([Environment]::GetFolderPath('MyPictures')) 'RemoteShutter'),
    [ValidateSet('', 'back', 'front')][string]$Camera = '',
    [ValidateSet('', 'off', 'auto', 'on')][string]$Flash = '',
    [ValidateSet('', 'portrait', 'landscapeRight', 'landscapeLeft', 'portraitUpsideDown')][string]$Orientation = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest の進捗表示は遅いので消す

function Exit-WithError([string]$Message) {
    Write-Host $Message -ForegroundColor Red
    exit 1
}

# URL から接続先とトークンを取り出す
try {
    $uri = [Uri]$Url
} catch {
    Exit-WithError "URL の形がおかしいです: $Url"
}
if ($uri.Query -notmatch '(?:^\?|&)token=([^&]+)') {
    Exit-WithError 'URL に ?token=... が入っていません。iPhone の画面に出ている URL をそのまま貼ってください。'
}
$token = [Uri]::UnescapeDataString($Matches[1])
$base = $uri.GetLeftPart([UriPartial]::Authority)
$auth = 'token=' + [Uri]::EscapeDataString($token)

# 接続確認
try {
    $status = Invoke-RestMethod -Uri "$base/status?$auth" -TimeoutSec 10 -UseBasicParsing
} catch {
    Exit-WithError "iPhone につながりません($base)。同じ Wi-Fi か、アプリが前面に開いているか確認してください。`n$($_.Exception.Message)"
}
Write-Host ("接続OK: RemoteShutter v{0} (build {1}) / 最大 {2}x{3}" -f $status.version, $status.build, $status.camera.maxPhotoWidth, $status.camera.maxPhotoHeight)

# 設定の変更(指定したものだけ)
$settings = @()
if ($Camera) { $settings += "camera=$Camera" }
if ($Flash) { $settings += "flash=$Flash" }
if ($Orientation) { $settings += "orientation=$Orientation" }
if ($settings.Count -gt 0) {
    Invoke-RestMethod -Method Post -Uri ("$base/settings?$auth&" + ($settings -join '&')) -TimeoutSec 10 -UseBasicParsing | Out-Null
    Write-Host ('設定を変更: ' + ($settings -join ', '))
    if ($Camera) { Start-Sleep -Seconds 1 }   # カメラの切り替えを待つ
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$OutDir = (Resolve-Path $OutDir).Path
Write-Host "保存先: $OutDir"

$ok = 0
for ($i = 1; $i -le $Count; $i++) {
    $started = Get-Date
    $tmp = Join-Path $OutDir ('.capture-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $res = Invoke-WebRequest -Method Post -Uri "$base/capture?$auth" -OutFile $tmp -PassThru -TimeoutSec 60 -UseBasicParsing
        $name = $res.Headers['X-Filename']
        if (-not $name) { $name = 'IMG_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff') + '.jpg' }
        $dest = Join-Path $OutDir $name
        Move-Item -LiteralPath $tmp -Destination $dest -Force
        $mb = (Get-Item -LiteralPath $dest).Length / 1MB
        $sec = ((Get-Date) - $started).TotalSeconds
        Write-Host ("[{0}/{1}] {2}  {3}x{4}  {5:N1}MB  {6:N1}秒" -f $i, $Count, $name, $res.Headers['X-Photo-Width'], $res.Headers['X-Photo-Height'], $mb, $sec)
        $ok++
    } catch {
        Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
        Write-Warning ("[{0}/{1}] 撮影に失敗: {2}" -f $i, $Count, $_.Exception.Message)
    }

    if ($i -lt $Count -and $IntervalSec -gt 0) {
        $wait = $IntervalSec - ((Get-Date) - $started).TotalSeconds
        if ($wait -gt 0) { Start-Sleep -Milliseconds ([int]($wait * 1000)) }
    }
}

Write-Host "完了: $ok / $Count 枚を保存しました"
if ($ok -lt $Count) { exit 2 }
