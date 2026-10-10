import fs from 'node:fs';
import path from 'node:path';
import http from 'node:http';
import vm from 'node:vm';
import zlib from 'node:zlib';
import { createRequire } from 'node:module';

// Full native-www regression runner. Never makes live account/backend requests.
// Chromium swipe uses real browser touch dispatch via CDP (implicit capture included).
// WebKit taps are native Playwright touchscreen taps; its swipe is an explicitly
// limited synthetic PointerEvent check because Playwright exposes no WebKit swipe API.
const require = createRequire(import.meta.url);
const playwright = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const out = path.resolve(process.env.QA_OUT || 'adhkar-browser-output');
fs.mkdirSync(out, { recursive: true });
const platformRoots = {
  ios: path.resolve(process.env.IOS_ROOT || 'ios'),
  android: path.resolve(process.env.ANDROID_ROOT || 'android'),
};
const requestedPlatforms = (process.env.QA_PLATFORMS || 'ios,android').split(',');
const requestedEngines = (process.env.QA_ENGINES || 'chromium,webkit').split(',');
const fixedTime = new Date('2026-10-10T12:00:00Z');
const datePadded = '2026-10-10';
const dateHisn = '2026-10-10';
const results = [];

function wwwFor(root, platform) {
  const candidates = platform === 'android' ? [path.join(root, 'app/src/main/assets/www'), root] : [path.join(root, 'www'), root];
  const found = candidates.find(item => fs.existsSync(path.join(item, 'index.html')));
  if (!found) throw new Error(`No native www/index.html at ${root}`);
  return found;
}
function readAsset(www, name) {
  const file = path.join(www, 'assets', name);
  if (fs.existsSync(file)) return fs.readFileSync(file, 'utf8');
  return zlib.gunzipSync(fs.readFileSync(file + '.gz')).toString('utf8');
}
function fixtureData(www) {
  const code = readAsset(www, 'hisnul-muslim-data-v331.js').replace(/^export /gm, '');
  return vm.runInNewContext(code + '\n({chapters:HISN_CHAPTERS,groups:HISN_GROUPS})', {}, { timeout: 1000 });
}
const mime = { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.woff2': 'font/woff2', '.woff': 'font/woff', '.ttf': 'font/ttf', '.png': 'image/png', '.svg': 'image/svg+xml', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.mp3': 'audio/mpeg' };
async function serve(www) {
  const server = http.createServer((req, res) => {
    let pathname = new URL(req.url, 'http://localhost').pathname;
    try { pathname = decodeURIComponent(pathname); } catch {
      res.writeHead(404); res.end('Unexpanded build-time URL'); return;
    }
    let file = path.resolve(www, '.' + pathname);
    if (!file.startsWith(www + path.sep) && file !== www) { res.writeHead(403); res.end(); return; }
    if (pathname === '/' || !path.extname(pathname)) file = path.join(www, 'index.html');
    try {
      const zipped = !fs.existsSync(file) && fs.existsSync(file + '.gz');
      const data = zipped ? zlib.gunzipSync(fs.readFileSync(file + '.gz')) : fs.readFileSync(file);
      res.writeHead(200, { 'Content-Type': mime[path.extname(file)] || 'application/octet-stream', 'Cache-Control': 'no-store' });
      res.end(data);
    } catch { res.writeHead(404); res.end('Missing local asset'); }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  return { server, base: `http://127.0.0.1:${server.address().port}` };
}
function trpcData(name) {
  if (/^(auth\.|adhkarGoals\.|prayerTimes\.|prayerSettings\.)/.test(name)) return null;
  if (/list|getAll|settings|categories|content|announcements|notifications/i.test(name)) return [];
  return null;
}
async function safeNetwork(context, base, requests) {
  await context.route('**/*', async route => {
    const request = route.request(), url = new URL(request.url());
    if (url.protocol === 'data:' || url.protocol === 'blob:') return route.continue();
    if (url.pathname.startsWith('/api/') || url.origin !== base) {
      const names = decodeURIComponent(url.pathname.split('/api/trpc/')[1] || '').split(',');
      requests.push({ method: request.method(), path: url.pathname, mocked: true, local: url.origin === base });
      if (url.pathname.includes('/api/trpc/')) {
        const values = names.map(name => ({ result: { data: { json: trpcData(name) } } }));
        return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(url.searchParams.get('batch') === '1' ? values : values[0]) });
      }
      return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ user: null }) });
    }
    return route.continue();
  });
}
async function attachDiagnostics(context, platform, storage) {
  await context.addInitScript(({ platform, storage }) => {
    window.__munibinNativeApp = true;
    window.__munibinNativePlatform = platform;
    if (document.documentElement) document.documentElement.dataset.munibinNativePlatform = platform;
    else document.addEventListener('DOMContentLoaded', () => { document.documentElement.dataset.munibinNativePlatform = platform; }, { once: true });
    for (const [key, value] of Object.entries(storage)) localStorage.setItem(key, typeof value === 'string' ? value : JSON.stringify(value));
    window.__qaEvents = []; window.__qaMutations = [];
    const add = EventTarget.prototype.addEventListener, remove = EventTarget.prototype.removeEventListener;
    const relevant = new Set(['pointerdown', 'pointermove', 'pointerup', 'pointercancel', 'lostpointercapture', 'gotpointercapture', 'click', 'keydown']);
    EventTarget.prototype.addEventListener = function(type, listener, options) {
      if (relevant.has(type) && this instanceof Element) {
        this.__qaListeners ||= {};
        this.__qaListeners[type] = (this.__qaListeners[type] || 0) + 1;
      }
      return add.call(this, type, listener, options);
    };
    EventTarget.prototype.removeEventListener = function(type, listener, options) {
      if (relevant.has(type) && this instanceof Element && this.__qaListeners) this.__qaListeners[type] = Math.max(0, (this.__qaListeners[type] || 0) - 1);
      return remove.call(this, type, listener, options);
    };
    for (const type of relevant) add.call(document, type, event => {
      if (!event.target?.closest?.('.munibin-hisn-reader-card,.munibin-hisn-reader-completion')) return;
      window.__qaEvents.push({ type, trusted: event.isTrusted, id: event.pointerId, pointerType: event.pointerType,
        target: event.target.tagName + '.' + event.target.className, targetCapture: event.target.hasPointerCapture?.(event.pointerId),
        cardCapture: event.target.closest('.munibin-hisn-reader-card,.munibin-hisn-reader-completion')?.hasPointerCapture?.(event.pointerId),
        x: event.clientX, y: event.clientY, at: Math.round(performance.now()) });
      if (window.__qaEvents.length > 180) window.__qaEvents.shift();
    }, { capture: true, passive: true });
    add.call(document, 'DOMContentLoaded', () => {
      new MutationObserver(records => {
        for (const record of records) {
          const target = record.target;
          if (!(target instanceof Element) || !target.matches('.munibin-hisn-reader-card,.munibin-hisn-reader-completion')) continue;
          window.__qaMutations.push({ attr: record.attributeName, value: target.getAttribute(record.attributeName), at: Math.round(performance.now()) });
          if (window.__qaMutations.length > 100) window.__qaMutations.shift();
        }
      }).observe(document.documentElement, { subtree: true, attributes: true, attributeFilter: ['data-adhkar-swipe', 'data-adhkar-motion', 'data-adhkar-busy', 'data-adhkar-dragging', 'data-complete'] });
    });
  }, { platform, storage });
}
async function snapshot(page) {
  return page.evaluate(() => {
    const card = document.querySelector('.munibin-hisn-reader-card,.munibin-hisn-reader-completion');
    const top = document.querySelector('.munibin-adhkar-top-controls');
    return { card: card && { label: card.getAttribute('aria-label'), text: card.querySelector('.munibin-hisn-reader-text')?.textContent?.trim().slice(0, 600),
      className: card.className, data: { ...card.dataset }, listeners: card.__qaListeners, touchAction: getComputedStyle(card).touchAction,
      rect: (() => { const r = card.getBoundingClientRect(); return { x: r.x, y: r.y, width: r.width, height: r.height }; })(),
      counter: card.querySelector('.munibin-hisn-reader-counter')?.textContent, complete: card.classList.contains('munibin-hisn-reader-completion') },
      top: top && { top: top.getBoundingClientRect().top, sectionPadding: getComputedStyle(top.parentElement).paddingTop },
      events: window.__qaEvents, mutations: window.__qaMutations, storage: { ...localStorage }, body: document.body.innerText.slice(0, 600) };
  });
}
function signature(s) { return s.card?.complete ? '__complete__' : `${s.card?.label || ''}|${s.card?.text || ''}`; }
async function settled(page) { await page.waitForTimeout(1200); }
async function openAdvanced(page, chapter) {
  await page.locator('.munibin-hisn-search input').fill(chapter.title);
  const chapterButton = page.locator('.munibin-hisn-chapter').filter({ hasText: chapter.title }).first();
  await chapterButton.waitFor({ timeout: 10000 });
  await chapterButton.click();
  await page.locator('.munibin-hisn-reader-card').waitFor({ timeout: 10000 });
  await settled(page);
}
async function touchTap(page, locator) {
  await locator.scrollIntoViewIfNeeded();
  const r = await locator.boundingBox();
  if (!r) throw new Error('Touch target has no bounding box');
  await page.touchscreen.tap(r.x + r.width / 2, r.y + r.height / 2);
}
async function swipe(page, engine, delta, targetKind = 'nested') {
  const card = page.locator('.munibin-hisn-reader-card');
  await card.scrollIntoViewIfNeeded();
  const point = await page.evaluate(({ targetKind, delta }) => {
    const card = document.querySelector('.munibin-hisn-reader-card'), r = card.getBoundingClientRect();
    const y = Math.max(20, Math.min(innerHeight - 70, r.top + Math.min(150, r.height / 3)));
    const x = delta > 0 ? Math.max(50, r.left + r.width * .28) : Math.min(innerWidth - 50, r.left + r.width * .72);
    let target = document.elementFromPoint(x, y);
    if (targetKind === 'root') {
      // Physical root-card padding ensures no implicit capture transfer from child.
      return { x: r.left + 5, y, root: true, target: card.tagName };
    }
    return { x, y, root: false, target: target?.tagName, targetClass: target?.className };
  }, { targetKind, delta });
  if (engine === 'chromium') {
    const cdp = await page.context().newCDPSession(page);
    const touchPoints = (x, y) => [{ x, y, id: 7, radiusX: 5, radiusY: 5, force: 1 }];
    await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: touchPoints(point.x, point.y) });
    for (let i = 1; i <= 10; i++) {
      await page.waitForTimeout(16);
      await cdp.send('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: touchPoints(point.x + delta * i / 10, point.y + 1) });
    }
    await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
    await cdp.detach();
  } else {
    await page.evaluate(async ({ point, delta }) => {
      const card = document.querySelector('.munibin-hisn-reader-card');
      const target = point.root ? card : document.elementFromPoint(point.x, point.y);
      const dispatch = (type, x, y, buttons) => target.dispatchEvent(new PointerEvent(type, { bubbles: true, cancelable: true, pointerId: 7, pointerType: 'touch', isPrimary: true, clientX: x, clientY: y, button: 0, buttons }));
      dispatch('pointerdown', point.x, point.y, 1);
      for (let i = 1; i <= 10; i++) { await new Promise(resolve => setTimeout(resolve, 16)); dispatch('pointermove', point.x + delta * i / 10, point.y + 1, 1); }
      dispatch('pointerup', point.x + delta, point.y + 1, 0);
    }, { point, delta });
  }
  await settled(page);
  return { ...point, method: engine === 'chromium' ? 'CDP native touch (trusted)' : 'synthetic PointerEvent only (no native implicit-capture claim)' };
}

function makeStorage(mode, caseName, data) {
  const storage = { 'munibin:adhkar-view:v1': mode === 'advanced' ? 'hisn' : 'simple', mutoon_font_preference: 'amiri' };
  if (mode === 'simple' && caseName !== 'swipe') {
    const items = data.chapters.find(c => c.id === 27).items;
    if (caseName === 'auto') {
      storage[`motoon-adhkar-progress:guest:${datePadded}:morning`] = { [items[0].id]: items[0].count - 1 };
    } else {
      const last = items.at(-1);
      storage[`motoon-adhkar-progress:guest:${datePadded}:morning`] = Object.fromEntries(items.map(item => [item.id, item.count - (item.id === last.id ? 1 : 0)]));
      storage['munibin:adhkar-simple-sequence:v408:guest'] = { day: datePadded, positions: { morning: last.id } };
    }
  }
  if (mode === 'advanced' && caseName === 'review') {
    const chapter = data.chapters.find(c => c.id === 3);
    storage['munibin:hisn-progress:v1:guest'] = { day: dateHisn, counts: Object.fromEntries(chapter.items.map(item => [item.id, item.count - 1])) };
  }
  return storage;
}
async function runCase(browser, engine, platform, base, mode, caseName, data) {
  const name = `${platform}-${engine}-${mode}-${caseName}`;
  const result = { name, platform, engine, mode, case: caseName, checks: [], errors: [], requests: [], limitation: engine === 'webkit' && caseName === 'swipe' ? 'WebKit PointerEvent swipe is synthetic; real UIKit/WKWebView gesture not tested' : null };
  const context = await browser.newContext({ viewport: { width: 393, height: 852 }, isMobile: true, hasTouch: true, deviceScaleFactor: 1, timezoneId: 'Europe/Berlin',
    userAgent: platform === 'android' ? 'Mozilla/5.0 (Linux; Android 14; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36 MunibinNative/Android' : 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1' });
  const page = await context.newPage();
  page.on('pageerror', error => result.errors.push(String(error)));
  await safeNetwork(context, base, result.requests);
  await attachDiagnostics(context, platform, makeStorage(mode, caseName, data));
  await page.clock.setFixedTime(fixedTime);
  const check = (label, passed, detail = null) => result.checks.push({ label, passed: !!passed, detail });
  try {
    await page.goto(base + '/adhkar', { waitUntil: 'domcontentloaded' });
    await page.locator('.munibin-adhkar-top-controls').waitFor({ timeout: 25000 });
    if (mode === 'advanced') await openAdvanced(page, data.chapters.find(c => c.id === (caseName === 'review' ? 3 : 1)));
    else { await page.locator('.munibin-hisn-reader-card').waitFor({ timeout: 12000 }); await settled(page); }
    result.before = await snapshot(page);
    result.topControls = result.before.top;
    check('card has swipe dataset and native pointer listeners', !!result.before.card?.data.adhkarSwipe && result.before.card?.listeners?.pointerdown > 0, result.before.card?.listeners);
    check('card touch-action permits vertical scroll, not horizontal browser pan', /pan-y|none/.test(result.before.card?.touchAction || ''), result.before.card?.touchAction);
    if (caseName === 'swipe') {
      result.gesture = await swipe(page, engine, 130, 'nested');
      result.afterNext = await snapshot(page);
      check('RTL nested-text finger swipe advances', signature(result.afterNext) !== signature(result.before));
      if (signature(result.afterNext) !== signature(result.before)) {
        result.previousGesture = await swipe(page, engine, -130, 'nested');
        result.afterPrevious = await snapshot(page);
        check('reverse nested-text swipe returns to prior dhikr', signature(result.afterPrevious) === signature(result.before));
      } else {
        result.rootGesture = await swipe(page, engine, 130, 'root');
        result.afterRootSwipe = await snapshot(page);
        check('root-card padding finger swipe advances', signature(result.afterRootSwipe) !== signature(result.before));
      }
      const countsKey = mode === 'simple' ? `motoon-adhkar-progress:guest:${datePadded}:morning` : 'munibin:hisn-progress:v1:guest';
      const stored = (await snapshot(page)).storage[countsKey];
      check('swiping does not increment a dhikr counter', !stored || Object.values(mode === 'simple' ? JSON.parse(stored) : JSON.parse(stored).counts).every(value => value === 0));
    } else {
      await touchTap(page, page.locator('.munibin-hisn-reader-counter'));
      await page.waitForTimeout(100);
      result.afterTap = await snapshot(page);
      check('final count briefly shows done effect', result.afterTap.card?.data.complete === 'true' || signature(result.afterTap) !== signature(result.before));
      await settled(page);
      result.afterAdvance = await snapshot(page);
      check('single final count advances automatically without second tap', signature(result.afterAdvance) !== signature(result.before));
      if (caseName === 'review') {
        check('last final count reaches completion summary', result.afterAdvance.card?.complete);
        const review = page.getByRole('button', { name: 'مراجعة الأذكار', exact: true });
        if (await review.count()) {
          await touchTap(page, review);
          await settled(page);
          result.afterReview = await snapshot(page);
          check('one review tap returns to first dhikr', !!result.afterReview.card && !result.afterReview.card.complete);
        } else check('one review tap returns to first dhikr', false, 'review not available');
      }
    }
    check('no uncaught app JavaScript errors', result.errors.length === 0, result.errors);
  } catch (error) { result.failure = String(error); result.diagnostic = await snapshot(page).catch(() => null); }
  result.passed = !result.failure && result.checks.every(c => c.passed);
  await page.screenshot({ path: path.join(out, `${name}.png`), fullPage: false }).catch(() => {});
  fs.writeFileSync(path.join(out, `${name}.json`), JSON.stringify(result, null, 2));
  console.log(JSON.stringify({ name, passed: result.passed, failure: result.failure, checks: result.checks, nativeTouch: engine === 'chromium', errors: result.errors }));
  await context.close();
  return result;
}

for (const platform of requestedPlatforms) {
  const www = wwwFor(platformRoots[platform], platform), data = fixtureData(www), { server, base } = await serve(www);
  try {
    for (const engine of requestedEngines) {
      let browser;
      try {
        browser = await playwright[engine].launch({ headless: true });
        for (const mode of ['simple', 'advanced']) for (const caseName of ['swipe', 'auto', 'review']) results.push(await runCase(browser, engine, platform, base, mode, caseName, data));
      } catch (error) {
        const result = { platform, engine, passed: false, startupFailure: String(error) }; results.push(result); console.log(JSON.stringify(result));
      } finally { await browser?.close(); }
    }
  } finally { await new Promise(resolve => server.close(resolve)); }
}
const summary = { date: new Date().toISOString(), fullNativeApp: true, actualSource: platformRoots, passed: results.every(r => r.passed), caseCount: results.length,
  safety: 'All non-local and all API requests are intercepted with mock guest replies; no live account/backend requests',
  limitations: ['WebKit synthetic swipe does not validate native iOS implicit pointer capture; Chromium CDP gesture is trusted browser touch', 'Neither browser test runs inside native UIKit or Android WebView shell'],
  results: results.map(({ before, afterNext, afterPrevious, afterTap, afterAdvance, afterReview, afterRootSwipe, diagnostic, requests, ...item }) => item) };
fs.writeFileSync(path.join(out, 'summary.json'), JSON.stringify(summary, null, 2));
console.log('ADHKAR_BROWSER_SUMMARY ' + JSON.stringify(summary));
if (process.env.QA_ALLOW_FAILURE !== '1' && !summary.passed) process.exitCode = 1;
