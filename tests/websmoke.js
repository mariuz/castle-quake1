// Smoke test of the web build in headless Chromium (Playwright):
//
//   node tests/websmoke.js <url of castle-engine-output/web/dist/index.html> <out dir>
//
// 1. Starts E1M1 with ?autotest=..&demo=.. (the web build reads them from
//    the page URL), takes a screenshot of the canvas and saves the game to
//    a slot; the save reaches the browser's localStorage within a second.
// 2. Reloads the page: the files come back from localStorage and the save
//    loads.
// 3. ?game=quake plays the original content (id1 models and samples).
// 4. A touch screen page: the first touch shows the touch controls, a drag
//    on the move stick walks the player forward (between two screenshots
//    the eye moves) and the touches do not reach the engine as clicks.
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

  // 3. The original content (?game=quake, like -game quake): id1's models
  //    and samples, several of which end with a broken chunk that stopped
  //    the WebAssembly program when it was read
  const third = await run(page, withParams(base, { game: 'quake', autotest: 'e1m1', demo: 'W:3,S' }), [
    /Loaded model "v_shot_original"/,
    /View: map e1m1/,
  ], 150, 'websmoke_3.png');
  report('the original Quake content loads (?game=quake)', third);

  // 4. Touch: a tap shows the controls, a held drag on the move stick walks
  const touchPage = await browser.newPage({ viewport: { width: 1280, height: 720 }, hasTouch: true });
  const touchLines = [];
  const touchErrors = [];
  touchPage.on('console', m => touchLines.push(m.text()));
  touchPage.on('pageerror', e => touchErrors.push(String(e)));
  await touchPage.goto(withParams(base, { autotest: 'e1m1', demo: 'W:6,S,W:5,S,W:2' }), { waitUntil: 'load', timeout: 180000 });
  const waitFor = async (re, seconds) => {
    const end = Date.now() + seconds * 1000;
    while (Date.now() < end) {
      if (touchLines.some(l => re.test(l))) return true;
      await touchPage.waitForTimeout(250);
    }
    return false;
  };
  const views = () => touchLines.filter(l => /View: map e1m1/.test(l))
    .map(l => parseFloat(l.match(/eye \S+ (\S+)/)[1]));
  if (await waitFor(/Successfully initialized map "maps\/e1m1\.bsp"/, 150)) {
    const box = await touchPage.locator('canvas').first().boundingBox();
    const cdp = await touchPage.context().newCDPSession(touchPage);
    const touch = (type, points) => cdp.send('Input.dispatchTouchEvent', { type, touchPoints: points });
    const x = box.x + box.width * 0.15;
    const y = box.y + box.height * 0.75;
    // A first tap turns the controls on
    await touch('touchStart', [{ x: box.x + box.width * 0.5, y: box.y + box.height * 0.5, id: 1 }]);
    await touch('touchEnd', []);
    await waitFor(/View: map e1m1/, 30);
    // The move stick: down on the left, dragged up past the stick's radius, held
    await touch('touchStart', [{ x, y, id: 2 }]);
    for (let i = 1; i <= 10; i++) {
      await touch('touchMove', [{ x, y: y - 15 * i, id: 2 }]);
      await touchPage.waitForTimeout(30);
    }
    const end = Date.now() + 20000;
    while (Date.now() < end && views().length < 2) {
      await touch('touchMove', [{ x, y: y - 150, id: 2 }]);
      await touchPage.waitForTimeout(200);
    }
    await touch('touchEnd', []);
  }
  await touchPage.waitForTimeout(500);
  fs.writeFileSync(path.join(outDir, 'websmoke_touch.log'), touchLines.join('\n'));
  const eyes = views();
  const touchMissing = [/Touch controls shown \(a touch was seen\)/].filter(re => !touchLines.some(l => re.test(l)));
  const crashed = touchLines.filter(l => /unreachable|RuntimeError|Runtime error|An unhandled exception/.test(l));
  const walked = eyes.length >= 2 && eyes[1] - eyes[0] > 100;
  report('a touch shows the touch controls and the move stick walks', {
    missing: touchMissing, errors: touchErrors.concat(crashed).concat(walked ? [] :
      ['the move stick did not walk (eye y ' + eyes.join(' -> ') + ')']) });
  console.log('touch: eye y ' + eyes.join(' -> '));

  await browser.close();
  process.exit(failed ? 1 : 0);
})().catch(e => { console.log('FAIL script: ' + e); process.exit(1); });
