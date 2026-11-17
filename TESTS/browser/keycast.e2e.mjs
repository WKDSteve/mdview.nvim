// TESTS/browser/keycast.e2e.mjs -- tier 3: the keycast overlay in a REAL browser.
//
// The way relay -> tab of mdview.nvim/overlay-keycast: a POST /keys reaches every tab, the keycast overlay (on
// through ?overlays=keycast, as the launcher passes it) shows the line as a pill that fades out, a tab without the
// overlay shows nothing, the overlay switched on live (\x05 control) shows the next batch, and a reloaded tab is not
// seeded with keys typed before it was there (the route is ephemeral). The Neovim side (ui.screenkey ->
// mdview.core.keycast -> the batch) is covered by the Lua specs; this script plays it by POSTing the batch as
// lua/mdview/adapter/ws_client.lua's send_keys does.
//
//   node TESTS/browser/keycast.e2e.mjs        (needs `npm run build:go`, `npm run build`, chromium)
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
const key = 'e2e/keycast.md';
const base = `http://127.0.0.1:${port}`;
const doc = ['# Keycast', '', 'last paragraph', ''].join('\n');

relay = spawn(
  exe,
  ['--port', String(port), '--token', token, '--web-root', webRoot, '--open=false'],
  { stdio: ['ignore', 'ignore', 'ignore'] },
);

const failures = [];
const check = (cond, msg) => {
  console.log(`${cond ? '  ok   ' : '  FAIL '}${msg}`);
  if (!cond) failures.push(msg);
};
const update = body =>
  fetch(`${base}/update?key=${encodeURIComponent(key)}&token=${token}`, { method: 'POST', body });
// The batch as lua/mdview/core/keycast.lua builds it; the route takes no key.
const keys = async text => {
  const res = await fetch(`${base}/keys?token=${token}`, {
    method: 'POST',
    body: JSON.stringify({ text }),
  });
  return res.status;
};
const control = fields =>
  fetch(`${base}/control?key=${encodeURIComponent(key)}&token=${token}`, {
    method: 'POST',
    body: JSON.stringify(fields),
  });

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
  const open = async overlays => {
    const page = await browser.newPage({ viewport: { width: 900, height: 600 } });
    const extra = overlays ? `&overlays=${overlays}` : '';
    await page.goto(`${base}/?key=${encodeURIComponent(key)}&token=${token}${extra}`);
    await page.waitForFunction(() => document.body.innerText.includes('last paragraph'), null, {
      timeout: 15000,
    });
    return page;
  };
  const pillText = page =>
    page.evaluate(() => document.querySelector('.mdview-keycast')?.textContent ?? null);
  const pillOn = page =>
    page.evaluate(
      () =>
        document.querySelector('.mdview-keycast')?.classList.contains('mdview-keycast-on') ?? false,
    );

  await update(doc);
  const on = await open('keycast');
  const off = await open('');

  check((await keys(':w<CR>')) === 204, 'POST /keys is taken');
  await on.waitForFunction(
    () => document.querySelector('.mdview-keycast')?.textContent === ':w<CR>',
    null,
    { timeout: 5000 },
  );
  check(await pillOn(on), 'the tab with the overlay shows the keys as a pill');
  const opacity = await on.evaluate(async () => {
    await new Promise(r => setTimeout(r, 200)); // past the fade-in transition
    return getComputedStyle(document.querySelector('.mdview-keycast')).opacity;
  });
  check(opacity === '1', `the pill is fully visible (opacity ${opacity})`);
  mkdirSync(outDir, { recursive: true });
  await on.screenshot({ path: resolve(outDir, 'keycast.png') });
  console.log(`screenshot: ${resolve(outDir, 'keycast.png')}`);
  check((await pillText(off)) === null, 'a tab without the overlay draws no pill');

  await on.waitForFunction(
    () => !document.querySelector('.mdview-keycast')?.classList.contains('mdview-keycast-on'),
    null,
    { timeout: 4000 },
  );
  check(true, 'the pill fades out after the last batch');

  // Switched on live (`:MDView overlay keycast on` during a session): the next batch shows.
  await control({ overlay: { name: 'keycast', on: true } });
  await off.waitForFunction(() => document.querySelector('.mdview-keycast') !== null, null, {
    timeout: 5000,
  });
  await keys('dd j' + '×' + '3');
  await off.waitForFunction(
    () => document.querySelector('.mdview-keycast')?.textContent === 'dd j×3',
    null,
    { timeout: 5000 },
  );
  check(true, 'the overlay switched on live shows the next batch');

  // Ephemeral: a reloaded tab shows nothing typed before it was there.
  await keys('secret?');
  await on.waitForFunction(
    () => document.querySelector('.mdview-keycast')?.textContent === 'secret?',
    null,
    { timeout: 5000 },
  );
  await on.reload();
  await on.waitForFunction(() => document.body.innerText.includes('last paragraph'), null, {
    timeout: 15000,
  });
  await new Promise(r => setTimeout(r, 500));
  check(
    (await pillText(on)) === '',
    `a reloaded tab is not seeded with keys (${JSON.stringify(await pillText(on))})`,
  );
} catch (e) {
  failures.push(String(e));
  console.log(`  FAIL ${e}`);
} finally {
  await browser?.close();
  relay.kill();
}
process.exit(failures.length ? 1 : 0);
