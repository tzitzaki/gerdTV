// gerdTV web player (served by gerdtv-host, src/lib.rs has the API). Plain JavaScript, no build step.
//
// How it works:
// - The session cookie (HttpOnly, set by the login link's hand-over) goes with every request; a 401 shows "Session
//   ended" for good, since only a new link from the app logs in again.
// - Sections: TV, Movies, Series, as in the app: groups (Favourites first), a group's items as a list or tiles,
//   the section's search on top; Movies and Series show Continue watching above their groups.
// - Playing: <video src="/s/<key>">; the host answers with a redirect to the provider's stream, so the browser plays
//   it directly. Browsers without built-in HLS (Firefox) get hls.js. A refused tokenised address is tried once as
//   the provider's plain address (?plain=1); still refused: "not playable in this browser".
//
// Debugging: the browser's network panel shows /api calls (401 = session over) and the /s/ redirect's target.

'use strict';

const $ = (id) => document.getElementById(id);
const de = (navigator.language || '').toLowerCase().startsWith('de');
const T = de
  ? {
      tv: 'TV', movies: 'Filme', series: 'Serien', search: 'Suchen', favourites: 'Favoriten', cont: 'Weiterschauen',
      play: 'Abspielen', resume: 'Fortsetzen bei', episodes: 'Folgen', empty: 'Nichts gefunden.', left: 'noch',
      extend: '+3 Std', endedTitle: 'Sitzung beendet',
      ended: 'Öffne einen neuen Login-Link aus der gerdTV-App: Einstellungen → Konto → Web-Player.',
      notPlayable: 'In diesem Browser nicht abspielbar. Versuche Safari oder Chrome.', now: 'Jetzt', next: 'Danach',
      more: 'Mehr',
    }
  : {
      tv: 'TV', movies: 'Movies', series: 'Series', search: 'Search', favourites: 'Favourites', cont: 'Continue watching',
      play: 'Play', resume: 'Continue at', episodes: 'Episodes', empty: 'Nothing found.', left: 'left',
      extend: '+3 h', endedTitle: 'Session ended',
      ended: 'Open a new login link from the gerdTV app: Settings → Account → Web player.',
      notPlayable: 'Not playable in this browser. Try Safari or Chrome.', now: 'Now', next: 'Next',
      more: 'More',
    };
document.querySelectorAll('[data-t]').forEach((e) => (e.textContent = T[e.dataset.t] || e.textContent));
$('search').placeholder = T.search;

const state = {
  section: 'live',
  // Each section's view stack: {type: 'groups'|'items'|'search'|'details', ...}.
  stack: [],
  tiles: { live: false, movie: true, series: true },
  favs: new Set(),
  expires: 0,
  serverOffset: 0,
};
try {
  Object.assign(state.tiles, JSON.parse(localStorage.getItem('gerdtv.tiles') || '{}'));
} catch (_) {}

async function api(path, body) {
  const r = await fetch(path, body === undefined ? {} : {
    method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body),
  });
  if (r.status === 401) {
    sessionOver();
    throw new Error('session');
  }
  if (!r.ok) throw new Error((await r.json().catch(() => ({}))).error || r.status);
  return r.json();
}

function el(tag, cls, text) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text !== undefined) e.textContent = text;
  return e;
}

function img(src, cls) {
  if (!src) return el('div', cls || 'ph');
  const i = el('img', cls);
  i.loading = 'lazy';
  i.alt = '';
  i.src = src;
  i.onerror = () => i.replaceWith(el('div', cls || 'ph'));
  return i;
}

function time(ts) {
  return new Date(ts * 1000).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: false });
}

// ---- session ----

async function session() {
  const s = await api('/api/session');
  state.expires = s.expires;
  state.serverOffset = s.now - Date.now() / 1000;
  tick();
}

function tick() {
  const left = Math.max(0, state.expires - (Date.now() / 1000 + state.serverOffset));
  const h = Math.floor(left / 3600), m = Math.floor((left % 3600) / 60);
  $('left').textContent = `${h}:${String(m).padStart(2, '0')} ${T.left}`;
  if (left <= 0 && state.expires) sessionOver();
}

/// The session is over: stop what plays (its controls are under the overlay) and say so.
function sessionOver() {
  if (playing) closePlayer(false);
  $('ended').hidden = false;
}
setInterval(tick, 30000);

$('extend').onclick = async () => {
  const r = await api('/api/extend', {});
  state.expires = r.expires;
  tick();
};

// ---- navigation ----

function current() {
  return state.stack[state.stack.length - 1];
}

function go(view) {
  state.stack.push(view);
  render();
}

$('back').onclick = () => {
  state.stack.pop();
  render();
};

document.querySelectorAll('#rail [data-section]').forEach((b) => {
  b.onclick = () => {
    state.section = b.dataset.section;
    document.querySelectorAll('#rail [data-section]').forEach((x) => x.classList.toggle('active', x === b));
    $('search').value = '';
    state.stack = [{ type: 'groups' }];
    render();
  };
});

$('mode').onclick = () => {
  state.tiles[state.section] = !state.tiles[state.section];
  try {
    localStorage.setItem('gerdtv.tiles', JSON.stringify(state.tiles));
  } catch (_) {}
  render();
};

let searchTimer;
$('search').oninput = () => {
  clearTimeout(searchTimer);
  searchTimer = setTimeout(() => {
    const q = $('search').value.trim();
    // A new search replaces the last one, and a page opened from it (typing there starts over).
    while (state.stack.length > 1 && ['search', 'details'].includes(current().type)) state.stack.pop();
    if (q) state.stack.push({ type: 'search', q });
    render();
  }, 200);
};

// Typing anywhere starts the search, as in the app.
document.addEventListener('keydown', (e) => {
  if (!$('player').hidden) {
    if (e.key === 'Escape') closePlayer();
    return;
  }
  if (document.activeElement === $('search') || e.ctrlKey || e.metaKey || e.altKey) return;
  if (e.key.length === 1 && /\S/.test(e.key)) $('search').focus();
  if (e.key === 'Escape' && state.stack.length > 1) $('back').click();
});

async function render() {
  const view = current();
  const names = { live: T.tv, movie: T.movies, series: T.series };
  $('back').hidden = state.stack.length <= 1;
  $('title').textContent = view.title || names[state.section];
  const c = $('content');
  const token = (render.token = (render.token || 0) + 1);
  const out = el('div');
  try {
    if (view.type === 'groups') await groups(out);
    else if (view.type === 'items') await items(out, view);
    else if (view.type === 'search') await search(out, view);
    else if (view.type === 'details') await details(out, view);
  } catch (e) {
    if (e.message !== 'session') out.append(el('p', 'empty', String(e.message || e)));
  }
  if (token !== render.token) return; // a newer view started meanwhile
  c.replaceChildren(out);
  c.scrollTop = 0;
  // Which view shows, once it has loaded ("movie:items"): for tests, and a hint when debugging.
  document.body.dataset.ready = `${state.section}:${view.type}`;
}

// ---- lists ----

async function groups(out) {
  if (state.section !== 'live') {
    const cont = (await api('/api/continue')).filter((h) => state.section === 'movie' ? h.key.startsWith('movie:') : !h.key.startsWith('movie:'));
    if (cont.length) {
      const shelf = el('div', 'shelf');
      shelf.append(el('h2', '', T.cont));
      shelf.append(list(cont, true));
      out.append(shelf);
    }
  }
  const cats = await api(`/api/categories?kind=${state.section}`);
  const rows = el('div', 'rows');
  for (const g of cats) {
    const r = el('div', 'row');
    r.tabIndex = 0;
    const t = el('div', 't');
    t.append(el('div', 'n', g.favourites ? `★ ${T.favourites}` : g.name));
    r.append(t, el('div', 'c', String(g.count)));
    r.onclick = () => go({ type: 'items', title: g.favourites ? T.favourites : g.name, category: g.id, favourites: !!g.favourites });
    r.onkeydown = (e) => e.key === 'Enter' && r.click();
    rows.append(r);
  }
  out.append(rows);
}

/// The host serves a group 200 items at a time: a More row at the end loads the next 200 into the same list.
const PAGE = 200;

async function items(out, view) {
  const q = view.favourites ? 'favourites=1' : `category=${encodeURIComponent(view.category)}`;
  const hits = await api(`/api/items?kind=${state.section}&${q}&offset=0`);
  if (!hits.length) return out.append(el('p', 'empty', T.empty));
  const box = list(hits);
  out.append(box);
  let offset = hits.length;
  if (view.favourites || hits.length < PAGE) return;
  const more = el('button', 'primary more', T.more);
  more.onclick = async () => {
    more.disabled = true;
    const next = await api(`/api/items?kind=${state.section}&${q}&offset=${offset}`);
    offset += next.length;
    for (const child of [...list(next).children]) box.append(child);
    more.disabled = false;
    if (next.length < PAGE) more.remove();
  };
  out.append(more);
}

async function search(out, view) {
  const hits = await api(`/api/search?kind=${state.section}&q=${encodeURIComponent(view.q)}`);
  out.append(hits.length ? list(hits) : el('p', 'empty', T.empty));
}

/// Rows or tiles for items; live rows get now/next.
function list(hits, shelf) {
  const tiles = shelf || state.tiles[state.section];
  const box = el('div', tiles ? 'tiles' : 'rows');
  const live = [];
  for (const h of hits) {
    const e = el('div', tiles ? 'tile' : 'row');
    e.tabIndex = 0;
    if (tiles) {
      e.append(img(h.logo), el('div', 'n', h.name));
    } else {
      const t = el('div', 't');
      t.append(el('div', 'n', `${state.favs.has(h.key) ? '★ ' : ''}${h.name}`));
      const sub = el('div', 's');
      t.append(sub);
      if (h.key.startsWith('live:')) live.push([h.key, sub]);
      e.append(img(h.logo), t);
    }
    if (h.duration) {
      const p = el('div', 'progress');
      const i = el('i');
      i.style.width = `${Math.min(100, (100 * h.position) / h.duration)}%`;
      p.append(i);
      e.append(p);
    }
    e.onclick = () => open(h);
    e.onkeydown = (ev) => ev.key === 'Enter' && e.click();
    box.append(e);
  }
  if (live.length) nowNext(live);
  return box;
}

async function nowNext(pairs) {
  const nn = await api(`/api/nownext?keys=${pairs.map((p) => encodeURIComponent(p[0])).join(',')}`);
  nn.forEach((x, i) => {
    if (x.now) pairs[i][1].textContent = `${time(x.now.start)} ${x.now.title}${x.next ? ` · ${time(x.next.start)} ${x.next.title}` : ''}`;
  });
}

function open(h) {
  if (h.key.startsWith('live:') || h.key.startsWith('episode:') || h.position) return play(h, h.position || 0);
  go({ type: 'details', title: h.name, item: h });
}

async function details(out, view) {
  const h = view.item;
  const d = await api(`/api/details?key=${encodeURIComponent(h.key)}`);
  const box = el('div', 'details');
  box.append(img(h.logo, 'poster'));
  const info = el('div', 'info');
  info.append(el('h2', '', h.name));
  info.append(el('p', 'meta', [d.release, d.genre, d.duration ? `${Math.round(d.duration / 60)} min` : '', d.rating ? `★ ${d.rating}` : ''].filter(Boolean).join(' · ')));
  info.append(el('p', '', d.plot));
  if (d.cast) info.append(el('p', 'meta', d.cast));
  if (h.key.startsWith('movie:')) {
    const play1 = el('button', 'primary', T.play);
    play1.onclick = () => play(h, 0);
    info.append(play1);
    if (d.resume) {
      const r = el('button', 'primary', `${T.resume} ${Math.floor(d.resume / 60)} min`);
      r.onclick = () => play(h, d.resume);
      info.append(r);
    }
  }
  const fav = el('button', '', state.favs.has(h.key) ? '★' : '☆');
  fav.onclick = async () => {
    await toggleFav(h.key);
    fav.textContent = state.favs.has(h.key) ? '★' : '☆';
  };
  info.append(fav);
  box.append(info);
  out.append(box);
  if (h.key.startsWith('series:')) {
    out.append(el('h2', '', T.episodes));
    out.append(list(await api(`/api/episodes?key=${encodeURIComponent(h.key)}`)));
  }
}

async function toggleFav(key) {
  const on = !state.favs.has(key);
  await api('/api/favourite', { key, on });
  if (on) state.favs.add(key);
  else state.favs.delete(key);
}

// ---- player ----

const video = $('video');
let playing = null;
let hls = null;
let saveTimer = null;
/// The pending seek to where a movie was left (removed when the player closes, so it can't seek the next stream).
let resumeSeek = null;

function nativeHls() {
  return video.canPlayType('application/vnd.apple.mpegurl') !== '';
}

function loadHlsJs() {
  if (window.Hls) return Promise.resolve();
  return new Promise((ok, fail) => {
    const s = document.createElement('script');
    s.src = '/hls.min.js';
    s.onload = ok;
    s.onerror = fail;
    document.head.append(s);
  });
}

async function play(h, from) {
  playing = { item: h, plain: false, from };
  $('player').hidden = false;
  $('error').hidden = true;
  $('now').textContent = h.name;
  $('next').textContent = '';
  $('fav').textContent = state.favs.has(h.key) ? '★' : '☆';
  await start();
  if (h.key.startsWith('live:')) {
    const [x] = await api(`/api/nownext?keys=${encodeURIComponent(h.key)}`).catch(() => [{}]);
    if (x && x.now) $('now').textContent = `${h.name} · ${time(x.now.start)} ${x.now.title}`;
    if (x && x.next) $('next').textContent = `${T.next} ${time(x.next.start)} ${x.next.title}`;
  } else {
    clearInterval(saveTimer);
    saveTimer = setInterval(saveProgress, 15000);
  }
}

async function start() {
  const p = playing;
  const src = `/s/${encodeURIComponent(p.item.key)}${p.plain ? '?plain=1' : ''}`;
  stopHls();
  clearResumeSeek();
  const live = p.item.key.startsWith('live:');
  if (live && !nativeHls()) {
    try {
      await loadHlsJs();
    } catch (_) {
      return failed();
    }
    // Closed (or another item started) while hls.js loaded: nothing to start.
    if (playing !== p) return;
    if (!window.Hls || !window.Hls.isSupported()) return failed();
    hls = new window.Hls();
    hls.on(window.Hls.Events.ERROR, (_, d) => d.fatal && retryOrFail());
    hls.loadSource(src);
    hls.attachMedia(video);
  } else {
    video.src = src;
  }
  if (p.from) {
    resumeSeek = () => {
      resumeSeek = null;
      video.currentTime = p.from;
    };
    video.addEventListener('loadedmetadata', resumeSeek, { once: true });
  }
  video.play().catch(() => {});
}

video.onerror = () => playing && retryOrFail();

function clearResumeSeek() {
  if (resumeSeek) video.removeEventListener('loadedmetadata', resumeSeek);
  resumeSeek = null;
}

function retryOrFail() {
  if (!playing) return;
  if (!playing.plain) {
    playing.plain = true;
    start();
  } else failed();
}

function failed() {
  $('error').textContent = T.notPlayable;
  $('error').hidden = false;
}

function stopHls() {
  if (hls) {
    hls.destroy();
    hls = null;
  }
}

function saveProgress() {
  if (!playing || playing.item.key.startsWith('live:') || !video.duration || !isFinite(video.duration)) {
    return Promise.resolve();
  }
  return api('/api/progress', { key: playing.item.key, position: Math.floor(video.currentTime), duration: Math.floor(video.duration) }).catch(() => {});
}

/// Stops and hides the player; `refresh`: then the view behind it shows the new position (after it was saved).
async function closePlayer(refresh = true) {
  const saved = saveProgress();
  clearInterval(saveTimer);
  stopHls();
  clearResumeSeek();
  video.removeAttribute('src');
  video.load();
  playing = null;
  $('player').hidden = true;
  if (!refresh) return;
  await saved;
  render();
}

$('close').onclick = () => closePlayer();
$('fav').onclick = async () => {
  if (!playing) return;
  await toggleFav(playing.item.key);
  $('fav').textContent = state.favs.has(playing.item.key) ? '★' : '☆';
};

// ---- start ----

(async () => {
  try {
    await session();
    state.favs = new Set(await api('/api/favkeys'));
    state.stack = [{ type: 'groups' }];
    render();
  } catch (_) {
    $('ended').hidden = false;
  }
})();
