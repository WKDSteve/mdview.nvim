// TESTS/browser/generated_view.e2e.mjs -- tier 3: a generated view (mdview.core.generated) in a REAL browser.
//
// A generated view's room is a scheme name with a Markdown extension (`caselog://case-1/app.log.md`), not a file
// path. Starts the built relay, feeds that room the way Neovim does (POST /update, POST /doc) and checks with
// Playwright that the tab renders the text as Markdown (not as the code view of a non-Markdown path), follows a
// new rendering (a filter in Neovim), and that a click on a relative link of the view reaches the relay's /nav
// queue under the view's room, which is what Neovim hands to the view's on_click (unit-tested in
// TESTS/nvim/generated_view_spec.lua).
//
//   node TESTS/browser/generated_view.e2e.mjs     (needs `npm run build:go`, `npm run build`, chromium)
//
// Exit 0 = passed, 1 = failed, 77 = a prerequisite is missing (a reported skip, never a green run).
import { spawn } from 'node:child_process';
import { existsSync, mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const exe = resolve(
  root,
  'native/server',
  process.platform === 'win32' ? 'mdview-server.exe' : 'mdview-server',
);
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
if (!existsSync(resolve(webRoot, 'index.html')))
  skip(`client bundle missing: ${webRoot} (npm run build)`);

let chromium;
try {
  ({ chromium } = await import('playwright-core'));
} catch {
  skip('playwright-core is not installed (npm install)');
}

const token = 'e2e-token';
const port = 43500 + Math.floor(Math.random() * 400);
const key = 'caselog://case-1/app.log.md';
const base = `http://127.0.0.1:${port}`;
const all = [
  '# app.log',
  '',
  '- [12:00:01 INFO start](entry/1)',
  '- [12:00:02 ERROR boom](entry/2)',
  '- [12:00:03 WARN slow](entry/3)',
].join('\n');
const errorsOnly = ['# app.log', '', '- [12:00:02 ERROR boom](entry/2)'].join('\n');

relay = spawn(
  exe,
  ['--port', String(port), '--token', token, '--web-root', webRoot, '--open=false'],
  {
    stdio: 'ignore',
  },
);
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
    await new Promise(r => setTimeout(r, 100));
  }
  try {
    browser = await chromium.launch();
  } catch (e) {
    skip(`no chromium for playwright-core: ${String(e).split('\n')[0]}`);
  }
  const page = await browser.newPage({ viewport: { width: 900, height: 700 } });
  // nav=1: what the launcher adds with experimental.click_navigate (on by default).
  await page.goto(`${base}/?key=${encodeURIComponent(key)}&token=${token}&nav=1`);
  await page.waitForSelector('#app, body');
  await post('update', all);
  await post('doc', key);
  await page.waitForFunction(() => document.body.innerText.includes('WARN slow'), null, {
    timeout: 15000,
  });

  const shape = () =>
    page.evaluate(() => {
      const r = document.getElementById('mdview-root');
      return {
        h1: r.querySelector('h1')?.textContent.trim() ?? null,
        links: [...r.querySelectorAll('a')].map(a => a.getAttribute('href')),
        text: r.innerText,
      };
    });
  const first = await shape();
  check(first.h1 === 'app.log', 'the view is rendered as Markdown (a heading, not a code view)');
  check(
    first.links.join(',') === 'entry/1,entry/2,entry/3',
    `its relative links are links (${first.links})`,
  );

  // A new rendering (the filter changed in Neovim) replaces the view in the open tab.
  await post('update', errorsOnly);
  await page.waitForFunction(() => !document.body.innerText.includes('WARN slow'), null, {
    timeout: 15000,
  });
  const second = await shape();
  check(second.links.join(',') === 'entry/2', 'the tab follows a new rendering of the view');

  // A click on a relative link goes to Neovim's /nav queue, under the view's room, and does not navigate.
  const before = page.url();
  await page.locator('#mdview-root a[href="entry/2"]').click();
  let queued = [];
  for (let i = 0; i < 40 && queued.length === 0; i++) {
    await page.waitForTimeout(50);
    queued = (await (await fetch(`${base}/nav?token=${token}`)).json()) ?? [];
  }
  check(
    queued.length === 1 && queued[0].key === key && queued[0].href === 'entry/2',
    `the click reached /nav as { key = view, href = "entry/2" } (${JSON.stringify(queued)})`,
  );
  check(page.url() === before, 'the tab did not navigate away');

  mkdirSync(outDir, { recursive: true });
  await page.screenshot({ path: resolve(outDir, 'generated_view.png') });
  console.log(`screenshot: ${resolve(outDir, 'generated_view.png')}`);
} catch (e) {
  failures.push(String(e));
  console.log(`  FAIL ${e}`);
} finally {
  await browser?.close();
  relay.kill();
}
process.exit(failures.length ? 1 : 0);
