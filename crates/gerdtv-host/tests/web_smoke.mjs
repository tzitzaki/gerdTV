// The web player in a real browser (run by tests/web_smoke.rs, `just test-web`): headless Chrome driven over its
// DevTools protocol with Node's built-in WebSocket (no test framework to install). Usage:
//   node web_smoke.mjs <login link> <screenshot dir>
// Exits non-zero with the step that failed. Chrome's binary: $CHROME, else google-chrome.
import { spawn } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const [link, shots] = process.argv.slice(2);
const profile = mkdtempSync(join(tmpdir(), 'gerdtv-chrome-'));
const chrome = spawn(process.env.CHROME || 'google-chrome', [
  '--headless=new', '--no-first-run', '--no-default-browser-check', '--disable-gpu', '--mute-audio',
  '--window-size=1280,800', `--user-data-dir=${profile}`, '--remote-debugging-port=0', 'about:blank',
], { stdio: 'ignore' });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let ws, id = 0;
const pending = new Map();
function send(method, params = {}) {
  return new Promise((ok, fail) => {
    const n = ++id;
    pending.set(n, { ok, fail });
    ws.send(JSON.stringify({ id: n, method, params }));
  });
}
const js = async (expr) => (await send('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true })).result.value;
async function until(what, expr, ms = 15000) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    if (await js(expr)) return;
    await sleep(100);
  }
  throw new Error(`timed out: ${what}`);
}
async function shot(name) {
  const { data } = await send('Page.captureScreenshot', { format: 'png' });
  mkdirSync(shots, { recursive: true });
  writeFileSync(join(shots, `web-${name}.png`), Buffer.from(data, 'base64'));
}

try {
  // Chrome writes its debugging port here once it listens.
  let port;
  for (let i = 0; i < 100 && !port; i++) {
    try { port = readFileSync(join(profile, 'DevToolsActivePort'), 'utf8').split('\n')[0]; } catch { await sleep(100); }
  }
  if (!port) throw new Error('chrome did not start');
  const targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
  ws = new WebSocket(targets.find((t) => t.type === 'page').webSocketDebuggerUrl);
  await new Promise((r) => (ws.onopen = r));
  ws.onmessage = (m) => {
    const d = JSON.parse(m.data);
    const p = pending.get(d.id);
    if (!p) return;
    pending.delete(d.id);
    d.error ? p.fail(new Error(d.error.message)) : p.ok(d.result);
  };
  await send('Page.enable');
  await send('Runtime.enable');

  // The link: the front door hands over to the player, which shows TV's groups.
  await send('Page.navigate', { url: link });
  await until('the player page with groups', `document.body.dataset.ready === 'live:groups' && document.querySelectorAll('#content .row').length > 0`);
  if (await js(`location.host`) === new URL(link).host) throw new Error('still on the front door');
  await until('the session timer', `/[0-9]:[0-9][0-9]/.test(document.getElementById('left').textContent)`);
  await shot('groups');
  // The biggest group (over 200 channels: the host pages by 200): More loads the rest into the list.
  await js(`(() => { const rows = [...document.querySelectorAll('#content .row')];
    rows.sort((a, b) => +b.querySelector('.c').textContent - +a.querySelector('.c').textContent); rows[0].click(); })()`);
  await until('the channels of a group', `document.body.dataset.ready === 'live:items' && document.querySelectorAll('#content .row').length > 0`);
  await shot('channels');
  if (!(await js(`document.querySelectorAll('#content .row').length === 200 && !!document.querySelector('.more')`))) {
    throw new Error('a group over 200 channels shows 200 and More');
  }
  await js(`document.querySelector('.more').click()`);
  await until('the next page', `document.querySelectorAll('#content .row').length > 200`);
  // Search narrows.
  await js(`(() => { const s = document.getElementById('search'); s.value = 'a'; s.dispatchEvent(new Event('input')); })()`);
  await until('search results', `document.body.dataset.ready === 'live:search' && document.querySelectorAll('#content .row').length > 0`);
  // Playing asks the host for the stream (its redirect goes to the provider).
  await js(`document.querySelector('#content .row').click()`);
  await until('the player', `!document.getElementById('player').hidden && (document.getElementById('video').getAttribute('src') || '').startsWith('/s/') || !!window.Hls`);
  await shot('player');
  await js(`document.getElementById('close').click()`);
  await until('the player closed', `document.getElementById('player').hidden`);
  // The session ends while something plays: the player stops (its controls would be under the overlay).
  await js(`document.querySelector('#content .row').click()`);
  await until('the player again', `!document.getElementById('player').hidden`);
  await send('Network.clearBrowserCookies');
  await js(`document.getElementById('fav').click()`);
  await until('stopped when the session ended', `!document.getElementById('ended').hidden && document.getElementById('player').hidden && !document.getElementById('video').getAttribute('src')`);
  // A new login for the rest of the walk (the link's cookie is gone): the test's second link.
  await send('Page.navigate', { url: process.argv[4] });
  await until('back in', `document.body.dataset.ready === 'live:groups'`);
  // Movies: tiles.
  await js(`document.querySelector('[data-section=movie]').click()`);
  await until('movie groups', `document.body.dataset.ready === 'movie:groups' && document.querySelectorAll('#content .row').length > 0`);
  await js(`document.querySelector('#content .row').click()`);
  await until('movie tiles', `document.body.dataset.ready === 'movie:items' && document.querySelectorAll('#content .tile').length > 0`);
  await shot('movies');
  // +3 h keeps the session; without the cookie it is over.
  await js(`document.getElementById('extend').click()`);
  await sleep(300);
  await send('Network.clearBrowserCookies');
  await send('Page.reload');
  await until('session ended', `!document.getElementById('ended').hidden`);
  await shot('ended');
  console.log('web smoke: ok');
  process.exitCode = 0;
} catch (e) {
  // Where it stood: the address and the page's text, plus a screenshot (web-failed.png).
  const where = ws ? await js(`location.href + ' | ' + document.body.innerText.slice(0, 400)`).catch(() => '') : '';
  if (ws) await shot('failed').catch(() => {});
  console.error(`web smoke: ${e.message}\n${where}`);
  process.exitCode = 1;
} finally {
  ws?.close();
  chrome.kill();
  await sleep(300);
  rmSync(profile, { recursive: true, force: true });
}
