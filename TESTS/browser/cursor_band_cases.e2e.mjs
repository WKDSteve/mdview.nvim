// TESTS/browser/cursor_band_cases.e2e.mjs -- tier 3: the corner cases of the cursor-line band in a REAL browser.
//
// The geometry points of the band's manual acceptance list (mdview.nvim/spotlight-mirror-live-check) that need
// no human judgement: a long source line that wraps over several screen lines is covered completely, a column
// motion on the same line does not move the band, a code block line gets exactly its own line, and a blank line
// between blocks gets the thin (4px) band below the previous block. cursor_band.e2e.mjs covers "sits on the line
// and follows it"; this is a script of its own so that each stays well inside the suite's case timeout.
//
//   node TESTS/browser/cursor_band_cases.e2e.mjs        (needs `npm run build:go`, `npm run build`, chromium)
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
const key = 'e2e/band-cases.md';
const base = `http://127.0.0.1:${port}`;
const longLine = Array.from({ length: 60 }, (_, i) => `word${i + 1}`).join(' long ');
// 1-based source lines: 3 = one long line (wraps), 4 = blank, 8..10 = code lines, 13 = last paragraph.
const doc = [
  '# Band cases', //                 1
  '', //                             2
  longLine, //                       3
  '', //                             4
  'short paragraph', //              5
  '', //                             6
  '```lua', //                       7
  'local alpha = 1', //              8
  'local beta = 2', //               9
  'local gamma = 3', //             10
  '```', //                         11
  '', //                            12
  'last paragraph', //              13
  '', //                            14
].join('\n');
const total = 14;

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
  await page.goto(`${base}/?key=${encodeURIComponent(key)}&token=${token}&cursor=line`);
  await page.waitForSelector('#app, body');
  await post('update', doc);
  await page.waitForFunction(() => document.body.innerText.includes('last paragraph'), null, {
    timeout: 15000,
  });

  // The cursor ping as Neovim sends it: "line/total/viewfrac/col" (viewfrac 0 is the placeholder for col).
  const cursorAt = async (line, col = 0) => {
    await post('scroll', `${line}/${total}/0/${col}`);
    await page.waitForTimeout(400);
  };
  const band = async () => {
    await page.waitForSelector('.mdview-cursor-bar', { state: 'attached', timeout: 5000 });
    return page.evaluate(() => {
      const bar = document.querySelector('.mdview-cursor-bar');
      const r = bar.getBoundingClientRect();
      return {
        top: r.top,
        bottom: r.bottom,
        height: r.height,
        shown: getComputedStyle(bar).display !== 'none',
      };
    });
  };
  const blockBox = (selector, text) =>
    page.evaluate(
      ([s, t]) => {
        const el = [...document.querySelectorAll(s)].find(e => e.textContent.trim().startsWith(t));
        const r = el.getBoundingClientRect();
        return {
          top: r.top,
          bottom: r.bottom,
          lineHeight: parseFloat(getComputedStyle(el).lineHeight) || 0,
        };
      },
      [selector, text],
    );
  // Viewport box of the text of one code line, measured over its characters (one rect per visual line). The
  // highlighter splits a line over several text nodes, so the range runs from node to node.
  const codeLineBox = text =>
    page.evaluate(t => {
      const code = document.querySelector('pre code') ?? document.querySelector('pre');
      const walker = document.createTreeWalker(code, NodeFilter.SHOW_TEXT);
      const nodes = [];
      let all = '';
      for (let n = walker.nextNode(); n; n = walker.nextNode()) {
        nodes.push({ n, at: all.length });
        all += n.data;
      }
      const from = all.indexOf(t);
      if (from < 0) return { top: Infinity, bottom: -Infinity };
      const to = from + t.length;
      const locate = off => {
        const hit = nodes.findLast(e => e.at <= off && off <= e.at + e.n.data.length);
        return [hit.n, off - hit.at];
      };
      const range = document.createRange();
      range.setStart(...locate(from));
      range.setEnd(...locate(to));
      let top = Infinity;
      let bottom = -Infinity;
      for (const r of range.getClientRects()) {
        if (r.height <= 0) continue;
        top = Math.min(top, r.top);
        bottom = Math.max(bottom, r.bottom);
      }
      return { top, bottom };
    }, text);
  const near = (a, b, px = 4) => Math.abs(a - b) <= px;

  // A long source line that wraps: the band covers all its screen lines.
  await cursorAt(3);
  const wrapped = await blockBox('p', 'word1 ');
  const onLong = await band();
  check(
    wrapped.bottom - wrapped.top > 2.5 * wrapped.lineHeight,
    'the long line wraps over at least three screen lines',
  );
  check(
    onLong.shown && onLong.top <= wrapped.top + 4 && onLong.bottom >= wrapped.bottom - 4,
    'the band covers the whole wrapped line',
  );

  // A column motion on the same line ("w", "$", "0") does not move the band.
  await cursorAt(3, 120);
  const afterCol = await band();
  check(
    near(afterCol.top, onLong.top, 1) && near(afterCol.height, onLong.height, 1),
    'a column motion leaves the band',
  );
  await cursorAt(3, 0);
  const backCol = await band();
  check(
    near(backCol.top, onLong.top, 1) && near(backCol.height, onLong.height, 1),
    'back to column 0, same band',
  );

  // A code block line: the band is exactly that one line.
  await cursorAt(9);
  const beta = await codeLineBox('local beta = 2');
  const onCode = await band();
  check(Number.isFinite(beta.top), 'the code line is rendered');
  check(
    onCode.shown && near(onCode.top, beta.top) && near(onCode.bottom, beta.bottom),
    `the band sits exactly on the code line (band ${onCode.top.toFixed(1)}..${onCode.bottom.toFixed(1)}, ` +
      `line ${beta.top.toFixed(1)}..${beta.bottom.toFixed(1)})`,
  );

  // A blank line between blocks: the thin band right below the previous block.
  await cursorAt(4);
  const onBlank = await band();
  // Measured again after the ping: a ping may scroll the page, and both boxes are in viewport coordinates.
  const previous = await blockBox('p', 'word1 ');
  check(
    onBlank.shown && near(onBlank.height, 4, 1),
    `the band on a blank line is 4px high (${onBlank.height}px)`,
  );
  check(
    near(onBlank.top, previous.bottom, 2),
    `the thin band starts at the bottom of the previous block (${onBlank.top.toFixed(1)} vs ${previous.bottom.toFixed(1)})`,
  );

  mkdirSync(outDir, { recursive: true });
  await page.screenshot({ path: resolve(outDir, 'cursor_band_cases.png') });
  console.log(`screenshot: ${resolve(outDir, 'cursor_band_cases.png')}`);
} catch (e) {
  failures.push(String(e));
  console.log(`  FAIL ${e}`);
} finally {
  await browser?.close();
  relay.kill();
}
process.exit(failures.length ? 1 : 0);
