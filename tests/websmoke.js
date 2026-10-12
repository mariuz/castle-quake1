// Smoke test of the web build in headless Chromium (Playwright):
//
//   node tests/websmoke.js <url of castle-engine-output/web/dist/index.html> <out dir>
//
// 1. Starts E1M1 with ?autotest=..&demo=.. (the web build reads them from
//    the page URL), takes a screenshot of the canvas and saves the game to
//    a slot; the save reaches the browser's localStorage within a second.
// 2. Reloads the page: the files come back from localStorage and the save
//    loads.
// Fails (exit code 1) on a page error, a WebAssembly crash or a missing log
// line. The screenshots are written to <out dir> (tests/websmoke_check.py
// checks they are not black).
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');

const base = process.argv[2];
const outDir = process.argv[3] || '.';
fs.mkdirSync(outDir, { recursive: true });

function withParams(url, params) {
  const u = new URL(url);
  for (const [k, v] of Object.entries(params)) u.searchParams.set(k, v);
  return u.toString();
}

async function run(page, url, expected, seconds, shot) {
  const lines = [];
  const errors = [];
  const onConsole = m => lines.push(m.text());
  const onError = e => errors.push(String(e));
  page.on('console', onConsole);
  page.on('pageerror', onError);
  await page.goto(url, { waitUntil: 'load', timeout: 180000 });
  const deadline = Date.now() + seconds * 1000;
  let missing = expected;
  while (Date.now() < deadline) {
    missing = expected.filter(re => !lines.some(l => re.test(l)));
    if (missing.length === 0) break;
    if (errors.length || lines.some(l => /unreachable|RuntimeError|Runtime error|An unhandled exception/.test(l))) break;
    await page.waitForTimeout(500);
  }
  // The canvas only: the page around it is white
  if (shot) await page.locator('canvas').first().screenshot({ path: path.join(outDir, shot) });
  page.off('console', onConsole);
  page.off('pageerror', onError);
  fs.writeFileSync(path.join(outDir, (shot || 'run') + '.log'), lines.join('\n'));
  const crashed = lines.filter(l => /unreachable|RuntimeError|Runtime error|An unhandled exception/.test(l));
  return { missing, errors: errors.concat(crashed), lines };
}

(async () => {
  const browser = await chromium.launch({
    headless: true,
    args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-webgl', '--ignore-gpu-blocklist',
      '--enable-unsafe-swiftshader', '--autoplay-policy=no-user-gesture-required'],
  });
  const page = await browser.newPage({ viewport: { width: 1280, height: 720 } });
  let failed = false;
  const report = (name, r) => {
    for (const re of r.missing) { console.log(`FAIL ${name}: no log line matching ${re}`); failed = true; }
    for (const e of r.errors) { console.log(`FAIL ${name}: ${e.slice(0, 300)}`); failed = true; }
    if (!r.missing.length && !r.errors.length) console.log(`ok   ${name}`);
  };

  // 1. Play, screenshot, save; the sync stores the save in localStorage
  const first = await run(page, withParams(base, { autotest: 'e1m1', demo: 'W:4,S,O:websmoke,W:3' }), [
    /Loaded map "maps\/e1m1\.bsp"/,
    /View: map e1m1/,
    /Saved game to "castle-config:\/save_websmoke\.sav"/,
    /Stored "save_websmoke\.sav"/,
  ], 150, 'websmoke_1.png');
  report('E1M1 starts, renders and saves to the browser storage', first);
  const stored = await page.evaluate(() => Object.keys(localStorage).filter(k => k.startsWith('castle-quake:')));
  console.log('localStorage: ' + stored.join(', '));
  if (!stored.includes('castle-quake:save_websmoke.sav')) { console.log('FAIL the save is not in localStorage'); failed = true; }

  // 2. A new visit: the save comes back and loads
  const second = await run(page, withParams(base, { autotest: 'e1m1', demo: 'W:3,L:websmoke,W:2,S' }), [
    /Restored \d+ files from the browser storage/,
    /Loaded game from "castle-config:\/save_websmoke\.sav"/,
  ], 150, 'websmoke_2.png');
  report('a reload restores the save and loads it', second);

  await browser.close();
  process.exit(failed ? 1 : 0);
})().catch(e => { console.log('FAIL script: ' + e); process.exit(1); });
