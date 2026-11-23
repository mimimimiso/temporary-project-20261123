// PC のブラウザで開く操作ページ(M2: 撮影とダウンロードだけ。ライブ映像は M3 で追加)
// raw string(#"..."#)なので、中の \ や ${} は Swift に解釈されない。

enum WebPage {
    static let html = #"""
<!doctype html>
<html lang="ja">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>RemoteShutter</title>
<style>
:root{--bg:#f5f5f2;--fg:#1d1d1b;--muted:#6c6b66;--card:#ffffff;--line:#e0dfd9;--accent:#c2410c;--accent-fg:#ffffff;--bad:#b91c1c;}
@media (prefers-color-scheme:dark){:root{--bg:#151514;--fg:#ecebe6;--muted:#9b9a94;--card:#20201e;--line:#353430;--accent:#fb7c3c;--accent-fg:#151514;--bad:#f87171;}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.55 system-ui,-apple-system,"Segoe UI","Yu Gothic UI",sans-serif}
main{max-width:1000px;margin:0 auto;padding:20px 16px 40px}
h1{font-size:20px;margin:0 0 4px}
h2{font-size:14px;margin:24px 0 8px;color:var(--muted);font-weight:600}
.muted{color:var(--muted)}
.bar{display:flex;flex-wrap:wrap;gap:12px;align-items:center;margin:16px 0}
button{font:inherit;font-weight:600;border:0;border-radius:10px;padding:12px 28px;background:var(--accent);color:var(--accent-fg);cursor:pointer}
button:disabled{opacity:.5;cursor:wait}
label{display:flex;gap:6px;align-items:center}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:12px}
#photo{display:block;max-width:100%;max-height:70vh;margin:0 auto;border-radius:6px}
#dl{display:inline-block;margin-top:8px;color:var(--accent)}
#msg.bad{color:var(--bad)}
pre{margin:0;max-height:240px;overflow:auto;font:12px/1.5 ui-monospace,Consolas,monospace;white-space:pre-wrap}
</style>
</head>
<body>
<main>
  <h1>RemoteShutter</h1>
  <div id="status" class="muted">接続確認中…</div>

  <div class="bar">
    <button id="shoot">撮影(Space)</button>
    <label><input type="checkbox" id="autosave"> 撮ったら自動で保存</label>
    <span id="msg" class="muted"></span>
  </div>

  <div id="result" class="card" hidden>
    <img id="photo" alt="撮影した写真">
    <a id="dl">保存</a>
  </div>

  <h2>iPhone のログ</h2>
  <div class="card"><pre id="log"></pre></div>
</main>
<script>
const token = new URLSearchParams(location.search).get('token') || '';
const q = 'token=' + encodeURIComponent(token);
const $ = (id) => document.getElementById(id);
let lastUrl = null;

try { $('autosave').checked = localStorage.getItem('autosave') === '1'; } catch (e) {}
$('autosave').addEventListener('change', () => {
  try { localStorage.setItem('autosave', $('autosave').checked ? '1' : '0'); } catch (e) {}
});

async function shoot() {
  const btn = $('shoot');
  if (btn.disabled) return;
  btn.disabled = true;
  $('msg').className = 'muted';
  $('msg').textContent = '撮影中…';
  const t0 = performance.now();
  try {
    const r = await fetch('/capture?' + q, { method: 'POST' });
    if (!r.ok) throw new Error(r.status + ' ' + (await r.text()));
    const blob = await r.blob();
    if (lastUrl) URL.revokeObjectURL(lastUrl);
    lastUrl = URL.createObjectURL(blob);
    const name = r.headers.get('X-Filename') || 'photo.jpg';
    $('photo').src = lastUrl;
    $('dl').href = lastUrl;
    $('dl').download = name;
    $('dl').textContent = name + ' を保存';
    $('result').hidden = false;
    const w = r.headers.get('X-Photo-Width'), h = r.headers.get('X-Photo-Height');
    const sec = ((performance.now() - t0) / 1000).toFixed(1);
    $('msg').textContent = `${w}×${h} / ${(blob.size / 1e6).toFixed(1)}MB / ${sec}秒`;
    if ($('autosave').checked) $('dl').click();
  } catch (e) {
    $('msg').className = 'bad';
    $('msg').textContent = '失敗: ' + e.message;
  } finally {
    btn.disabled = false;
  }
}

$('shoot').addEventListener('click', shoot);
document.addEventListener('keydown', (e) => {
  if (e.code === 'Space' && e.target.tagName !== 'INPUT') { e.preventDefault(); shoot(); }
});

async function poll() {
  try {
    const s = await (await fetch('/status?' + q)).json();
    const cam = s.camera.running ? `カメラ動作中(最大 ${s.camera.maxPhotoWidth}×${s.camera.maxPhotoHeight})` : 'カメラ停止中';
    $('status').textContent = `接続OK / v${s.version} build ${s.build} / iOS ${s.ios} / ${cam} / 撮影 ${s.captures} 回`;
  } catch (e) {
    $('status').textContent = '接続できません(iPhoneでアプリが前面に開いているか確認)';
  }
  try {
    const t = await (await fetch('/log?' + q)).text();
    const el = $('log');
    const atBottom = el.scrollTop + el.clientHeight >= el.scrollHeight - 4;
    el.textContent = t;
    if (atBottom) el.scrollTop = el.scrollHeight;
  } catch (e) {}
}
poll();
setInterval(poll, 2000);
</script>
</body>
</html>
"""#
}
