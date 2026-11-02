// TESTS/browser/cursor_band.e2e.mjs -- tier 3: the cursor-line band of the preview in a REAL browser.
//
// Starts the built relay, feeds it a document the way Neovim does (POST /update, POST /scroll) and checks
// with Playwright that `.mdview-cursor-bar` sits on the cursor line and follows it. The unit specs run in
// jsdom without layout; this is the check that needs real geometry.
//
//   node TESTS/browser/cursor_band.e2e.mjs        (needs `npm run build:go`, `npm run build`, chromium)
//
// Exit 0 = passed, 1 = failed, 77 = a prerequisite is missing (a reported skip, never a green run).
import { spawn } from 'node:child_process';
import { existsSync, mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const exe = resolve(root, 'native/server', process.platform === 'win32' ? 'mdview-server.exe' : 'mdview-server');
const webRoot = resolve(root, 'dist/client');
const outDir = resolve(process.env.MDVIEW_E2E_OUT ?? resolve(root, 'TESTS/browser/out'));
const SKIP = 77;

function skip(why) {
  console.log(`SKIP: ${why}`);
  process.exit(SKIP);
}
if (!existsSync(exe)) skip(`relay binary missing: ${exe} (npm run build:go)`);
if (!existsSync(resolve(webRoot, 'index.html'))) skip(`client bundle missing: ${webRoot} (npm run build)`);

let chromium;
try {
  ({ chromium } = await import('playwright-core'));
} catch {
  skip('playwright-core is not installed (npm install)');
}

const token = 'e2e-token';
const port = 43500 + Math.floor(Math.random() * 400);
const key = 'e2e/band.md';
const base = `http://127.0.0.1:${port}`;
const doc = ['# Title', '', 'first paragraph', '', 'second paragraph', '', 'third paragraph', ''].join('\n');

const relay = spawn(exe, ['--port', String(port), '--token', token, '--web-root', webRoot, '--open=false'], {
  stdio: 'ignore',
});
const failures = [];
const check = (cond, msg) => {
  console.log(`${cond ? '  ok   ' : '  FAIL '}${msg}`);
  if (!cond) failures.push(msg);
};
const post = (path, body) =>
  fetch(`${base}/${path}?key=${encodeURIComponent(key)}&token=${token}`, { method: 'POST', body });

let browser;
try {
  for (let i = 0; i < 50; i++) {
    try {
      if ((await fetch(`${base}/health`)).ok) break;
    } catch {
      /* not up yet */
    }
    await new Promise((r) => setTimeout(r, 100));
  }
  try {
    browser = await chromium.launch();
  } catch (e) {
    skip(`no chromium for playwright-core: ${String(e).split('\n')[0]}`);
  }
  const page = await browser.newPage({ viewport: { width: 900, height: 700 } });
  await page.goto(`${base}/?key=${encodeURIComponent(key)}&token=${token}&cursor=line`);
  await page.waitForSelector('#app, body');
  await post('update', doc);
  await page.waitForFunction(() => document.body.innerText.includes('third paragraph'), null, { timeout: 15000 });

  const bandTop = async () => {
    await page.waitForSelector('.mdview-cursor-bar', { state: 'attached', timeout: 10000 });
    return page.evaluate(() => {
      const bar = document.querySelector('.mdview-cursor-bar');
      const r = bar.getBoundingClientRect();
      return { top: r.top, bottom: r.bottom, shown: getComputedStyle(bar).display !== 'none' };
    });
  };
  const lineBox = (text) =>
    page.evaluate((t) => {
      const el = [...document.querySelectorAll('p, h1')].find((e) => e.textContent.trim() === t);
      const r = el.getBoundingClientRect();
      return { top: r.top, bottom: r.bottom };
    }, text);
  const covers = (band, box) => band.shown && band.top <= box.top + 4 && band.bottom >= box.bottom - 4;

  await post('scroll', '3/8');
  await page.waitForTimeout(600);
  let band = await bandTop();
  check(covers(band, await lineBox('first paragraph')), 'the band covers the line the cursor is on (line 3)');

  await post('scroll', '7/8');
  await page.waitForTimeout(600);
  const moved = await bandTop();
  check(covers(moved, await lineBox('third paragraph')), 'the band follows the cursor to line 7');
  check(moved.top !== band.top, 'the band moved');

  mkdirSync(outDir, { recursive: true });
  await page.screenshot({ path: resolve(outDir, 'cursor_band.png') });
  console.log(`screenshot: ${resolve(outDir, 'cursor_band.png')}`);
} catch (e) {
  failures.push(String(e));
  console.log(`  FAIL ${e}`);
} finally {
  await browser?.close();
  relay.kill();
}
process.exit(failures.length ? 1 : 0);
