// TESTS/browser/spotlight_mirror.e2e.mjs -- tier 3: the spotlight mirror in a REAL browser.
//
// The points of the mirror's manual acceptance list (mdview.nvim/spotlight-mirror-live-check) that need no human
// judgement, on the way relay -> tab: a POST /spotlight with a hit marks the token in the tab in the color that was
// sent, a changed state (set switch) and an empty one (clear, remove) update resp. clear the marks, a new color
// (colorscheme switch) arrives, a reloaded tab is seeded with the last state at once, and a common token in a large
// document paints at most `max` matches and reports the cap in the web log (the relay's "[client]" lines). The
// Neovim side (spotlight.nvim -> payload) is covered by the Lua specs; this script plays it by POSTing the payload
// as lua/mdview/adapter/ws_client.lua's send_spotlight does.
//
//   node TESTS/browser/spotlight_mirror.e2e.mjs        (needs `npm run build:go`, `npm run build`, chromium)
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
const key = 'e2e/spotlight.md';
const base = `http://127.0.0.1:${port}`;
const doc = [
  '# Spotlight mirror',
  '',
  'The request for customer ERR-4711 failed.',
  '',
  'A retry of ERR-4711 succeeded, DELTA was not involved.',
  '',
  'last paragraph',
  '',
].join('\n');
// 600 paragraphs with the same token: above the per-spotlight cap of 500.
const COMMON = 600;
const MAX = 500;
const bigDoc = [
  '# Large',
  '',
  ...Array.from({ length: COMMON }, (_, i) => `row ${i + 1} has TOKEN in it\n`),
  'end of large',
  '',
].join('\n');

// The relay's stdout is the web log: the page's clientLog lines come out as "[client] ...".
let relayOut = '';
relay = spawn(
  exe,
  ['--port', String(port), '--token', token, '--web-root', webRoot, '--open=false'],
  { stdio: ['ignore', 'pipe', 'ignore'] },
);
relay.stdout.setEncoding('utf8');
relay.stdout.on('data', chunk => {
  relayOut += chunk;
});

const failures = [];
const check = (cond, msg) => {
  console.log(`${cond ? '  ok   ' : '  FAIL '}${msg}`);
  if (!cond) failures.push(msg);
};
const update = body =>
  fetch(`${base}/update?key=${encodeURIComponent(key)}&token=${token}`, { method: 'POST', body });
// The payload as lua/mdview/core/spotlight_mirror.lua builds it; the route takes no key.
const spotlight = async (items, colors, max = MAX) => {
  const res = await fetch(`${base}/spotlight?token=${token}`, {
    method: 'POST',
    body: JSON.stringify({ type: 'spotlight', items, colors, max }),
  });
  return res.status;
};
const item = (text, slot) => ({ text, slot, line: false, kind: 'literal', ignoreCase: false });

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
  await page.goto(`${base}/?key=${encodeURIComponent(key)}&token=${token}`);
  await page.waitForSelector('#app, body');
  await update(doc);
  await page.waitForFunction(() => document.body.innerText.includes('last paragraph'), null, {
    timeout: 15000,
  });
  check(
    await page.evaluate(() => typeof CSS !== 'undefined' && !!CSS.highlights),
    'chromium paints with the CSS Custom Highlight API',
  );

  // What is painted in one highlight: the texts of its ranges in the live document (none when the highlight is
  // gone). A re-render replaces the DOM, so a range left over from before it sits on detached nodes and is not counted.
  const painted = name =>
    page.evaluate(
      n =>
        [...(CSS.highlights.get(n) ?? [])]
          .filter(r => r.startContainer.isConnected)
          .map(r => r.toString()),
      name,
    );
  const waitPainted = (name, count) =>
    page.waitForFunction(
      ([n, c]) =>
        [...(CSS.highlights.get(n) ?? [])].filter(r => r.startContainer.isConnected).length === c,
      [name, count],
      { timeout: 5000 },
    );
  // The background the highlight is drawn in, as the browser resolved it from the sent color.
  const paintedBg = name =>
    page.evaluate(
      n => getComputedStyle(document.querySelector('p'), `::highlight(${n})`).backgroundColor,
      name,
    );

  // A hit: the token is marked in the color that was sent.
  check(
    (await spotlight(
      [item('ERR-4711', 1)],
      [{ slot: 1, bg: '#ff8800', fg: '#101010', bold: false }],
    )) < 300,
    'POST /spotlight is taken',
  );
  await waitPainted('spotlight-1', 2);
  const hits = await painted('spotlight-1');
  check(
    hits.length === 2 && hits.every(t => t === 'ERR-4711'),
    `both occurrences of the token are marked (${JSON.stringify(hits)})`,
  );
  check(
    (await paintedBg('spotlight-1')) === 'rgb(255, 136, 0)',
    `the mark has the sent background (${await paintedBg('spotlight-1')})`,
  );
  mkdirSync(outDir, { recursive: true });
  await page.screenshot({ path: resolve(outDir, 'spotlight_mirror.png') });
  console.log(`screenshot: ${resolve(outDir, 'spotlight_mirror.png')}`);

  // A re-render (an edit in Neovim) keeps the marks.
  await update(doc.replace('last paragraph', 'last paragraph, edited'));
  await page.waitForFunction(() => document.body.innerText.includes('edited'), null, {
    timeout: 5000,
  });
  await waitPainted('spotlight-1', 2);
  check(true, 'the marks survive a re-render');

  // A changed state (":Spotlight sets switch", remove one, add another): the old marks go, the new ones come.
  await spotlight([item('DELTA', 2)], [{ slot: 2, bg: '#3366ff', bold: false }]);
  await waitPainted('spotlight-2', 1);
  check(
    (await painted('spotlight-1')).length === 0,
    'the spotlight that left the state is cleared',
  );
  check(
    (await paintedBg('spotlight-2')) === 'rgb(51, 102, 255)',
    `the new spotlight has its color (${await paintedBg('spotlight-2')})`,
  );

  // A colorscheme switch: same spotlights, new colors.
  await spotlight([item('DELTA', 2)], [{ slot: 2, bg: '#00aa55', bold: false }]);
  await page.waitForFunction(
    () =>
      getComputedStyle(document.querySelector('p'), '::highlight(spotlight-2)').backgroundColor ===
      'rgb(0, 170, 85)',
    null,
    { timeout: 5000 },
  );
  check(true, 'a new color reaches the tab');

  // A reloaded tab is seeded with the last state at once (the relay replays it on join).
  await page.reload();
  await page.waitForFunction(() => document.body.innerText.includes('edited'), null, {
    timeout: 15000,
  });
  await waitPainted('spotlight-2', 1);
  check(
    (await paintedBg('spotlight-2')) === 'rgb(0, 170, 85)',
    'a reloaded tab gets the last state and its colors',
  );

  // Clear (":Spotlight clear", the last one removed): nothing stays marked.
  await spotlight([], []);
  await waitPainted('spotlight-2', 0);
  check(
    await page.evaluate(() => [...CSS.highlights.keys()].every(n => !n.startsWith('spotlight'))),
    'an empty state clears every mark',
  );

  // A large document with a common token: at most MAX painted, the cap reported in the web log.
  await update(bigDoc);
  await page.waitForFunction(() => document.body.innerText.includes('end of large'), null, {
    timeout: 15000,
  });
  const started = Date.now();
  await spotlight([item('TOKEN', 3)], [{ slot: 3, bg: '#cc00cc', bold: false }]);
  await waitPainted('spotlight-3', MAX);
  check(true, `${COMMON} occurrences, ${MAX} marked (${Date.now() - started} ms to paint)`);
  const capLine = `[client] spotlight: 1 spotlight(s), ${MAX} match(es), 1 capped at ${MAX}`;
  for (let i = 0; i < 50 && !relayOut.includes(capLine); i++) {
    await new Promise(r => setTimeout(r, 100));
  }
  check(relayOut.includes(capLine), `the web log reports the cap ("${capLine}")`);
} catch (e) {
  failures.push(String(e));
  console.log(`  FAIL ${e}`);
} finally {
  await browser?.close();
  relay.kill();
}
process.exit(failures.length ? 1 : 0);
