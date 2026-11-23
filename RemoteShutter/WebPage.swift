// PC のブラウザで開く操作ページ(ライブ映像・撮影・向き・撮った写真の一覧・ログ)
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
:root{--bg:#f4f4f1;--fg:#1d1d1b;--muted:#6c6b66;--card:#ffffff;--line:#e0dfd9;--accent:#c2410c;--accent-fg:#ffffff;--ok:#15803d;--bad:#b91c1c;--stage:#0e0e0d;}
@media (prefers-color-scheme:dark){:root{--bg:#141413;--fg:#ecebe6;--muted:#9b9a94;--card:#1f1f1d;--line:#34332f;--accent:#fb7c3c;--accent-fg:#141413;--ok:#4ade80;--bad:#f87171;--stage:#000000;}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.55 system-ui,-apple-system,"Segoe UI","Yu Gothic UI",sans-serif}
.wrap{max-width:1400px;margin:0 auto;padding:16px}
header{display:flex;flex-wrap:wrap;align-items:center;gap:8px 14px;margin-bottom:14px}
header h1{font-size:18px;margin:0}
.pill{font-size:12px;font-weight:600;padding:2px 10px;border-radius:99px;border:1px solid currentColor}
.pill.ok{color:var(--ok)} .pill.bad{color:var(--bad)} .pill.wait{color:var(--muted)}
.muted{color:var(--muted)}
#info{font-size:13px}
.layout{display:grid;gap:16px;grid-template-columns:minmax(0,1fr)}
@media (min-width:900px){.layout{grid-template-columns:minmax(0,1fr) 320px}}
.stage{position:relative;background:var(--stage);border-radius:12px;min-height:260px;display:flex;align-items:center;justify-content:center;overflow:hidden}
#live{display:block;max-width:100%;max-height:calc(100vh - 120px);object-fit:contain}
#overlay{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;padding:16px;text-align:center;color:#d6d5cf;font-size:14px;background:rgba(0,0,0,.45)}
#overlay[hidden]{display:none}
#flash{position:absolute;inset:0;background:#fff;opacity:0;pointer-events:none;transition:opacity .35s ease-out}
#flash.on{opacity:.85;transition:none}
.panel{display:flex;flex-direction:column;gap:14px}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:14px}
.shutter{width:100%;font:inherit;font-size:17px;font-weight:700;border:0;border-radius:12px;padding:16px;background:var(--accent);color:var(--accent-fg);cursor:pointer}
.shutter:disabled{opacity:.55;cursor:progress}
.hint{font-size:12px;color:var(--muted);margin-top:6px;text-align:center}
#msg{font-size:13px;min-height:1.5em;margin-top:8px;overflow-wrap:anywhere}
#msg.bad{color:var(--bad)}
.field{display:flex;flex-direction:column;gap:4px;font-size:13px;color:var(--muted)}
select{font:inherit;color:var(--fg);background:var(--card);border:1px solid var(--line);border-radius:8px;padding:8px}
.check{display:flex;gap:8px;align-items:center;font-size:14px;margin-top:10px}
h2{font-size:13px;font-weight:600;color:var(--muted);margin:0 0 10px}
.gallery{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:8px}
.shot{display:flex;flex-direction:column;gap:2px;font-size:11px;color:var(--muted)}
.shot img{width:100%;aspect-ratio:1;object-fit:cover;border-radius:6px;background:var(--line);display:block}
.shot a{color:var(--accent);text-decoration:none}
details{margin-top:16px}
summary{cursor:pointer;color:var(--muted);font-size:13px}
pre{margin:8px 0 0;max-height:260px;overflow:auto;font:12px/1.5 ui-monospace,Consolas,monospace;white-space:pre-wrap;overflow-wrap:anywhere}
</style>
</head>
<body>
<div class="wrap">
  <header>
    <h1>RemoteShutter</h1>
    <span id="conn" class="pill wait">接続確認中</span>
    <span id="info" class="muted"></span>
  </header>

  <div class="layout">
    <div class="stage">
      <img id="live" alt="ライブ映像">
      <div id="flash"></div>
      <div id="overlay">ライブ映像に接続中…</div>
    </div>

    <aside class="panel">
      <div class="card">
        <button id="shoot" class="shutter">撮影</button>
        <div class="hint">Space キーでも撮影できます</div>
        <div id="msg" class="muted"></div>
      </div>

      <div class="card">
        <label class="field">向き(iPhone の構え方に合わせる)
          <select id="orient"></select>
        </label>
        <label class="check"><input type="checkbox" id="autosave"> 撮ったら自動で保存</label>
      </div>

      <div class="card">
        <h2>撮った写真(このページを閉じると消えます)</h2>
        <div id="gallery" class="gallery"></div>
        <div id="empty" class="muted" style="font-size:13px">まだありません</div>
      </div>
    </aside>
  </div>

  <details>
    <summary>iPhone のログ</summary>
    <pre id="log"></pre>
  </details>
</div>
<script>
const token = new URLSearchParams(location.search).get('token') || '';
const q = 'token=' + encodeURIComponent(token);
const $ = (id) => document.getElementById(id);
const MAX_SHOTS = 12;
const shots = [];
let online = null;
let orientReady = false;

// ---- 自動保存の設定(このブラウザだけに記憶) ----
try { $('autosave').checked = localStorage.getItem('autosave') === '1'; } catch (e) {}
$('autosave').addEventListener('change', () => {
  try { localStorage.setItem('autosave', $('autosave').checked ? '1' : '0'); } catch (e) {}
});

// ---- ライブ映像 ----
let retryTimer = null;
function connectLive() {
  clearTimeout(retryTimer);
  $('overlay').textContent = 'ライブ映像に接続中…';
  $('overlay').hidden = false;
  $('live').src = '/stream?' + q + '&t=' + Date.now();
}
$('live').addEventListener('load', () => { $('overlay').hidden = true; });
$('live').addEventListener('error', () => {
  $('overlay').textContent = 'ライブ映像が途切れました。再接続します…';
  $('overlay').hidden = false;
  clearTimeout(retryTimer);
  retryTimer = setTimeout(connectLive, 2000);
});

// ---- 撮影 ----
function flash() {
  const f = $('flash');
  f.classList.add('on');
  requestAnimationFrame(() => requestAnimationFrame(() => f.classList.remove('on')));
}

function addShot(url, name, w, h, size) {
  shots.unshift({ url });
  while (shots.length > MAX_SHOTS) URL.revokeObjectURL(shots.pop().url);

  const item = document.createElement('div');
  item.className = 'shot';
  const view = document.createElement('a');
  view.href = url; view.target = '_blank'; view.title = name;
  const img = document.createElement('img');
  img.src = url; img.alt = name; img.loading = 'lazy';
  view.appendChild(img);
  const meta = document.createElement('span');
  meta.textContent = `${w}×${h} ${(size / 1e6).toFixed(1)}MB`;
  const save = document.createElement('a');
  save.href = url; save.download = name; save.textContent = '保存';
  item.append(view, meta, save);

  const g = $('gallery');
  g.prepend(item);
  while (g.children.length > MAX_SHOTS) g.lastElementChild.remove();
  $('empty').hidden = true;
  return save;
}

async function shoot() {
  const btn = $('shoot');
  if (btn.disabled) return;
  btn.disabled = true;
  $('msg').className = 'muted';
  $('msg').textContent = '撮影中…';
  flash();
  const t0 = performance.now();
  try {
    const r = await fetch('/capture?' + q, { method: 'POST' });
    if (!r.ok) throw new Error(r.status + ' ' + (await r.text()));
    const blob = await r.blob();
    const url = URL.createObjectURL(blob);
    const name = r.headers.get('X-Filename') || 'photo.jpg';
    const w = r.headers.get('X-Photo-Width') || '?', h = r.headers.get('X-Photo-Height') || '?';
    const save = addShot(url, name, w, h, blob.size);
    const sec = ((performance.now() - t0) / 1000).toFixed(1);
    $('msg').textContent = `${name} / ${w}×${h} / ${(blob.size / 1e6).toFixed(1)}MB / ${sec}秒`;
    if ($('autosave').checked) save.click();
  } catch (e) {
    $('msg').className = 'bad';
    $('msg').textContent = '失敗: ' + e.message;
  } finally {
    btn.disabled = false;
  }
}
$('shoot').addEventListener('click', shoot);
document.addEventListener('keydown', (e) => {
  const tag = e.target.tagName;
  if (e.code === 'Space' && tag !== 'INPUT' && tag !== 'SELECT' && tag !== 'BUTTON') {
    e.preventDefault();
    shoot();
  }
});

// ---- 向き ----
$('orient').addEventListener('change', async () => {
  try {
    const r = await fetch('/settings?' + q + '&orientation=' + encodeURIComponent($('orient').value), { method: 'POST' });
    if (!r.ok) throw new Error(await r.text());
  } catch (e) {
    $('msg').className = 'bad';
    $('msg').textContent = '向きを変えられません: ' + e.message;
  }
});

function fillOrientations(s) {
  const sel = $('orient');
  if (!orientReady && Array.isArray(s.orientations)) {
    for (const o of s.orientations) {
      const opt = document.createElement('option');
      opt.value = o.value; opt.textContent = o.label;
      sel.appendChild(opt);
    }
    orientReady = true;
  }
  if (document.activeElement !== sel) sel.value = s.orientation;
}

// ---- 状態とログ ----
function setOnline(ok) {
  if (online === ok) return;
  const wasOffline = online === false;
  online = ok;
  $('conn').className = 'pill ' + (ok ? 'ok' : 'bad');
  $('conn').textContent = ok ? '接続中' : '切断';
  if (ok && (wasOffline || !$('live').src)) connectLive();
  if (!ok) {
    $('overlay').textContent = 'iPhone につながりません。アプリが前面に開いているか確認してください';
    $('overlay').hidden = false;
  }
}

async function poll() {
  try {
    const r = await fetch('/status?' + q);
    if (r.status === 401) {
      $('conn').className = 'pill bad';
      $('conn').textContent = 'トークンが違います';
      return;
    }
    const s = await r.json();
    setOnline(true);
    fillOrientations(s);
    const cam = s.camera.running ? `最大 ${s.camera.maxPhotoWidth}×${s.camera.maxPhotoHeight}` : 'カメラ停止中';
    $('info').textContent = `v${s.version} build ${s.build} / iOS ${s.ios} / ${cam} / 撮影 ${s.captures} 回`;
    if ($('live').naturalWidth > 0) $('overlay').hidden = true;
  } catch (e) {
    setOnline(false);
  }
  if ($('log').closest('details').open) {
    try {
      const t = await (await fetch('/log?' + q)).text();
      const el = $('log');
      const atBottom = el.scrollTop + el.clientHeight >= el.scrollHeight - 4;
      el.textContent = t;
      if (atBottom) el.scrollTop = el.scrollHeight;
    } catch (e) {}
  }
}
poll();
setInterval(poll, 2000);
</script>
</body>
</html>
"""#
}
