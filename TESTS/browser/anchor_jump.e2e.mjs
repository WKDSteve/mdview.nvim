// TESTS/browser/anchor_jump.e2e.mjs -- tier 3: a click on a table-of-contents link in a REAL browser.
//
// Starts the built relay, feeds it a document with a TOC the way Neovim does (POST /update) and checks with
// Playwright that hovering a `[x](#anchor)` link still opens the preview popup and that clicking it scrolls
// the preview to the heading. The rendered headings carry no ids, so the browser alone would not move; the
// jsdom spec (TESTS/client/anchorJump.dom.test.ts) has no layout, this is the check with real geometry.
//
//   node TESTS/browser/anchor_jump.e2e.mjs        (needs `npm run build:go`, `npm run build`, chromium)
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

let relay; // started below; a skip after that must not leave it running
function skip(why) {
  console.log(`SKIP: ${why}`);
  relay?.kill();
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
const key = 'e2e/toc.md';
const base = `http://127.0.0.1:${port}`;
const filler = Array.from({ length: 40 }, (_, i) => `filler paragraph ${i + 1}\n`);
const doc = [
  '# Title',
  '',
  '- [Usage notes](#usage-notes)',
  '- [Setup again](#setup-1)',
  '',
  '## Setup',
  '',
  ...filler,
  '## Usage Notes!',
  '',
  'usage text',
  '',
  ...filler,
  '## Setup',
  '',
  'second setup text',
  '',
  ...filler,
].join('\n');

relay = spawn(exe, ['--port', String(port), '--token', token, '--web-root', webRoot, '--open=false'], {
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
  await page.goto(`${base}/?key=${encodeURIComponent(key)}&token=${token}`);
  await page.waitForSelector('#app, body');
  await post('update', doc);
  await page.waitForFunction(() => document.body.innerText.includes('second setup text'), null, {
    timeout: 15000,
  });

  // Where a heading sits relative to the top of the scroll viewport (#mdview-root), and how far it scrolled.
  const headingPos = (nth, text) =>
    page.evaluate(
      ([n, t]) => {
        const root = document.getElementById('mdview-root');
        const el = [...root.querySelectorAll('h2')].filter((h) => h.textContent.trim() === t)[n];
        return {
          offset: el.getBoundingClientRect().top - root.getBoundingClientRect().top,
          scrollTop: root.scrollTop,
        };
      },
      [nth, text],
    );
  const settle = async () => {
    // scrollToBlock scrolls smoothly; wait until scrollTop stops changing.
    let last = -1;
    for (let i = 0; i < 60; i++) {
      const now = await page.evaluate(() => document.getElementById('mdview-root').scrollTop);
      if (now === last) return;
      last = now;
      await page.waitForTimeout(60);
    }
  };

  const link = page.locator('#mdview-root a[href="#usage-notes"]');
  await link.hover();
  // The popup opens after a 250 ms rest of the pointer.
  const popup = await page
    .waitForSelector('#mdview-link-hover', { timeout: 3000 })
    .then((el) => el.textContent())
    .catch(() => null);
  check(popup !== null && popup.includes('Usage Notes!'), 'hovering the TOC link still shows the preview popup');

  const before = await headingPos(0, 'Usage Notes!');
  check(before.offset > 700, 'the target heading starts out below the viewport');
  await link.click();
  await settle();
  const after = await headingPos(0, 'Usage Notes!');
  check(after.scrollTop > 0, 'clicking the TOC link scrolled the preview');
  check(after.offset >= -2 && after.offset < 120, `the heading sits at the top of the preview (${after.offset}px)`);

  await page.evaluate(() => (document.getElementById('mdview-root').scrollTop = 0));
  await settle();
  await page.locator('#mdview-root a[href="#setup-1"]').click();
  await settle();
  const second = await headingPos(1, 'Setup');
  check(second.offset >= -2 && second.offset < 120, '#setup-1 lands on the second "Setup" heading');

  mkdirSync(outDir, { recursive: true });
  await page.screenshot({ path: resolve(outDir, 'anchor_jump.png') });
  console.log(`screenshot: ${resolve(outDir, 'anchor_jump.png')}`);
} catch (e) {
  failures.push(String(e));
  console.log(`  FAIL ${e}`);
} finally {
  await browser?.close();
  relay.kill();
}
process.exit(failures.length ? 1 : 0);
