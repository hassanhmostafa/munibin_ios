// Service Worker — متون طالب العلم
// استراتيجية: CacheFirst لغلاف التطبيق حتى يبدأ فوراً دون اتصال، ثم تحديثات
// عامل الخدمة تتولى جلب الإصدار الجديد. قارئات المحتوى الثقيلة تُخزّن لاحقاً.
// الكاش يُحذف تلقائياً عند تغيير CACHE_VERSION.
// يجب تغيير الإصدار عند أي نشر لتفادي مزج هيكل صفحة جديد مع حزمة JavaScript قديمة.

const CACHE_VERSION = 'v423-prayer-format-iqama-1';
const CACHE_NAME = `munibin-${CACHE_VERSION}`;
// Native bundles already contain every Quran font, including offline. Avoid
// duplicating 604 color faces in Cache Storage during installation while the
// foreground reader is trying to load its next page. Web/PWA precaching stays.
const NATIVE_BUNDLED_ORIGIN = ['127.0.0.1', 'localhost'].includes(self.location.hostname) && self.location.port === '49321';
const QCF4_OFFLINE_CACHE_NAME = 'mutoon-qcf4-1441-tajweed-v362';
const QCF4_TAFSIR_CACHE_NAME = 'mutoon-qcf4-1441-tafsir-v2';
const QURAN_RECITER_AUDIO_CACHE_NAME = 'munibin-quran-reciter-audio-v1';
const ADHAN_AUDIO_CACHE_NAME = 'munibin-adhan-audio-v1';
const QURAN_RECITER_OFFLINE_PLAYBACK_PATH = '/__quran-reciter-offline-audio';
const QCF4_PAGE_DATA_ROOT = '/api/quran/qcf4/page';
const QCF4_FONT_ROOT = '/assets/tajweed-v362/fonts';
const QCF4_PAGE_COUNT = 604;
const QCF4_NAVIGATION_URL = '/api/quran/navigation';
const QURAN_RECITER_CATALOG_URL = '/api/quran/reciters';
const QCF4_WORD_SEARCH_URL = '/manus-storage/quran-tanzil-simple-search-1.1_d298971c.txt';
const qcf4OfflineUrls = [
  QCF4_NAVIGATION_URL,
  QCF4_WORD_SEARCH_URL,
  ...Array.from({ length: QCF4_PAGE_COUNT }, (_, index) => `${QCF4_PAGE_DATA_ROOT}/${String(index + 1).padStart(3, '0')}.json?reader=346`),
  ...Array.from({ length: QCF4_PAGE_COUNT }, (_, index) => `${QCF4_FONT_ROOT}/p${index + 1}.woff2`),
];
// صفحة البداية وخطها: يفتح القرآن قبل اكتمال تنزيل المصحف في نسخة الويب.
const qcf4StartupUrls = [
  QCF4_NAVIGATION_URL,
  QURAN_RECITER_CATALOG_URL,
  `${QCF4_PAGE_DATA_ROOT}/001.json?reader=346`,
  `${QCF4_FONT_ROOT}/p1.woff2`,
];
const qcf4FontUrls = [
  ...Array.from({ length: QCF4_PAGE_COUNT }, (_, index) => `${QCF4_FONT_ROOT}/p${index + 1}.woff2`),
];
let qcf4PrecachePromise = null;
let readerPrecachePromise = null;
let quranReaderPrecachePromise = null;
let qcf4CacheState = { status: 'idle', completed: 0, error: '' };
const APP_SHELL_URLS = [
  '/',
  '/index.html',
  '/manifest.json',
  '/apple-touch-icon-180.png',
  '/icon-192.png',
  '/icon-512.png',
];

// مهلة الشبكة قبل الرجوع للكاش (بالمللي ثانية)
const NETWORK_TIMEOUT_MS = 12000;

// ─── Install ────────────────────────────────────────────────────────────────
self.addEventListener('install', (event) => {
  // يتضمن الغلاف حزمة قارئ القرآن الأساسية حتى لا ينتظر Android الاتصال في البداية الباردة.
  event.waitUntil(
    caches.open(CACHE_NAME)
      .then((cache) => precacheAppInterface(cache))
      .then(() => cacheQcf4FontAssets())
      .then(() => cacheQcf4StartupAssets())
      .then(() => self.skipWaiting())
      .catch((error) => {
        // لا نفعّل إصداراً ناقصاً: يبقى عامل الخدمة السابق صالحاً حتى يكتمل التخزين.
        console.warn('[SW] تعذر إكمال التخزين المسبق الأساسي:', error);
        throw error;
      })
  );
});

async function cacheResourcesSequentially(cache, urls) {
  // لا تُنزّل ملفات كبيرة عديدة في وقت واحد؛ هذا أكثر استقراراً على الأجهزة المحدودة.
  for (const url of urls) {
    await cache.add(url);
  }
}

async function precacheAppInterface(cache) {
  await cacheResourcesSequentially(cache, APP_SHELL_URLS);

  const response = await fetch('/asset-manifest.json', { cache: 'no-store' });
  if (!response.ok) {
    throw new Error(`تعذر قراءة بيان أصول عدم الاتصال (${response.status}).`);
  }

  const manifest = await response.json();
  const interfaceAssets = Array.isArray(manifest.shellAssets)
    ? manifest.shellAssets.filter((url) => typeof url === 'string' && url.startsWith('/assets/') &&
        !(NATIVE_BUNDLED_ORIGIN && /^\/assets\/tajweed-v362\/fonts\/p\d+\.woff2$/.test(url)))
    : [];

  if (interfaceAssets.length === 0) {
    throw new Error('بيان أصول عدم الاتصال لا يحتوي على واجهة القراءة الأساسية.');
  }

  await cacheResourcesSequentially(cache, interfaceAssets);
}

async function cacheReaderAssets() {
  const response = await fetch('/asset-manifest.json', { cache: 'no-store' });
  if (!response.ok) throw new Error(`تعذر قراءة بيان موارد القراءة (${response.status}).`);
  const manifest = await response.json();
  const quranReaderAssetSet = new Set(
    Array.isArray(manifest.quranReaderAssets)
      ? manifest.quranReaderAssets.filter((url) => typeof url === 'string' && url.startsWith('/assets/'))
      : []
  );
  const readerAssets = Array.isArray(manifest.readerAssets)
    ? manifest.readerAssets.filter((url) => typeof url === 'string' && url.startsWith('/assets/') && !quranReaderAssetSet.has(url))
    : [];
  const cache = await caches.open(CACHE_NAME);

  for (const url of readerAssets) {
    try {
      if (await cache.match(url)) continue;
      await cache.add(url);
    } catch (error) {
      // فشل مورد قراءة واحد لا يمس الغلاف؛ سيعاد طلبه عند فتح الصفحة أو في فتح لاحق.
      console.warn('[SW] تعذر تخزين مورد قراءة في الخلفية:', url, error);
    }
  }
}

function beginReaderAssetCache() {
  readerPrecachePromise ??= cacheReaderAssets().finally(() => {
    readerPrecachePromise = null;
  });
  return readerPrecachePromise;
}

// قارئ القرآن يُحمّل ديناميكياً. نخزّنه مستقلاً قبل المتون الكبيرة حتى لا يبقى
// التطبيق على فهرس يشير إلى اسم chunk قديم عند فتح Android دون اتصال.
async function cacheQuranReaderAssets() {
  const response = await fetch('/asset-manifest.json', { cache: 'no-store' });
  if (!response.ok) throw new Error(`تعذر قراءة بيان قارئ القرآن (${response.status}).`);
  const manifest = await response.json();
  const quranReaderAssets = Array.isArray(manifest.quranReaderAssets)
    ? manifest.quranReaderAssets.filter((url) => typeof url === 'string' && url.startsWith('/assets/'))
    : [];
  const cache = await caches.open(CACHE_NAME);

  for (const url of quranReaderAssets) {
    if (await cache.match(url)) continue;
    await cache.add(url);
  }
}

function beginQuranReaderAssetCache() {
  quranReaderPrecachePromise ??= cacheQuranReaderAssets().catch((error) => {
    console.warn('[SW] تعذر تخزين حزمة قارئ القرآن في الخلفية:', error);
  }).finally(() => {
    quranReaderPrecachePromise = null;
  });
  return quranReaderPrecachePromise;
}

async function cacheQcf4StartupAssets() {
  const cache = await caches.open(QCF4_OFFLINE_CACHE_NAME);
  for (const url of qcf4StartupUrls) {
    if (NATIVE_BUNDLED_ORIGIN && isQcf4OfflineAsset(new URL(url, self.location.origin))) continue;
    try {
      const cached = await cache.match(url);
      if (cached) continue;
      const response = await fetch(url);
      if (!response?.ok) throw new Error(`تعذر تخزين أصل بداية القرآن (${response?.status ?? 'network'}).`);
      await cache.put(url, response);
    } catch (error) {
      // لا نمنع تثبيت غلاف التطبيق إذا تعذر مورد خارجي؛ يظل القارئ يحاول الشبكة لاحقاً.
      console.warn('[SW] تعذر تخزين أصل بداية قارئ القرآن:', error);
    }
  }
}

// تُحفظ الخطوط كلها عند تثبيت الإصدار، لا صفحة البداية فقط، كي يظهر رسم مصحف المدينة
// الرسمي لأي صفحة محفوظة حتى عندما يبدأ التطبيق لأول مرة في وضع عدم الاتصال.
async function cacheQcf4FontAssets() {
  if (NATIVE_BUNDLED_ORIGIN) return;
  const cache = await caches.open(QCF4_OFFLINE_CACHE_NAME);
  for (const url of qcf4FontUrls) {
    try {
      if (await cache.match(url)) continue;
      await cache.add(url);
    } catch (error) {
      console.warn('[SW] تعذر تخزين خط مصحف المدينة:', url, error);
    }
  }
}

// ─── Activate ───────────────────────────────────────────────────────────────
self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((cacheNames) => {
      return Promise.all(
        cacheNames
          .filter((name) => name !== CACHE_NAME && name !== QCF4_OFFLINE_CACHE_NAME && name !== QCF4_TAFSIR_CACHE_NAME && name !== QURAN_RECITER_AUDIO_CACHE_NAME && name !== ADHAN_AUDIO_CACHE_NAME) // احتفظ بكاش مصحف 1441 وتفسيره وتلاوات القراء وملف الأذان المنزلين
          .map((name) => caches.delete(name))
      );
    }).then(() => self.clients.claim()) // تحكّم في كل التبويبات المفتوحة فوراً
  );
});

// ─── Helper: NetworkFirst مع timeout ────────────────────────────────────────
function networkFirstWithTimeout(request, timeoutMs) {
  return new Promise((resolve, reject) => {
    let timedOut = false;

    const timeoutId = setTimeout(() => {
      timedOut = true;
      // انتهت المهلة — ارجع للكاش
      caches.match(request).then((cached) => {
        if (cached) resolve(cached);
        else reject(new Error('offline and no cache'));
      });
    }, timeoutMs);

    fetch(request).then((response) => {
      if (timedOut) return; // الـ timeout سبق
      clearTimeout(timeoutId);

      if (response && response.status === 200) {
        // خزّن النسخة الجديدة في الكاش
        const clone = response.clone();
        caches.open(CACHE_NAME).then((cache) => cache.put(request, clone));
      }
      resolve(response);
    }).catch((err) => {
      if (timedOut) return;
      clearTimeout(timeoutId);
      // فشلت الشبكة — ارجع للكاش
      caches.match(request).then((cached) => {
        if (cached) resolve(cached);
        else reject(err);
      });
    });
  });
}

function isQcf4OfflineAsset(url) {
  return url.pathname.startsWith(`${QCF4_PAGE_DATA_ROOT}/`) || url.pathname.startsWith(`${QCF4_FONT_ROOT}/`);
}

function isQcf4TafsirRequest(url) {
  return url.pathname.startsWith('/api/quran/qcf4/tafsir/');
}

function isQcf4NavigationRequest(url) {
  return url.pathname === QCF4_NAVIGATION_URL || url.pathname === QCF4_WORD_SEARCH_URL;
}

function isPublishedAdhanAudioRequest(url) {
  return url.pathname.startsWith('/manus-storage/adhan/') || url.pathname.startsWith('/api/audio/adhan/');
}

function isQuranReaderChunk(url) {
  return /^\/assets\/AdminQcf1441PreviewPage-[^/]+\.js$/.test(url.pathname);
}

async function matchCurrentQuranReaderChunk(cache) {
  const requests = await cache.keys();
  const currentRequest = requests.find((request) => isQuranReaderChunk(new URL(request.url)));
  return currentRequest ? cache.match(currentRequest) : undefined;
}

async function serveQuranReciterAudio(sourceUrl, request) {
  const cache = await caches.open(QURAN_RECITER_AUDIO_CACHE_NAME);
  const cached = await cache.match(sourceUrl);
  if (cached && cached.ok && cached.status !== 206) {
    // Media elements request byte ranges, including Safari's initial bytes=0-1
    // probe. Returning the entire cached 200 response breaks offline seeking.
    const blob = await cached.blob();
    const headers = new Headers(cached.headers);
    headers.delete('Content-Encoding');
    headers.delete('Transfer-Encoding');
    headers.delete('Content-Range');
    headers.set('Accept-Ranges', 'bytes');
    headers.set('Content-Length', String(blob.size));
    if (!headers.get('Content-Type') || headers.get('Content-Type') === 'application/octet-stream') {
      headers.set('Content-Type', 'audio/mpeg');
    }
    if (request.method === 'HEAD') return new Response(null, { status: 200, headers });
    const range = request.headers.get('Range');
    if (!range) return new Response(blob, { status: 200, headers });
    const match = /^bytes=(\d*)-(\d*)$/i.exec(range.trim());
    let start = 0;
    let end = blob.size - 1;
    if (match && (match[1] || match[2])) {
      if (!match[1]) start = Math.max(0, blob.size - Number(match[2]));
      else {
        start = Number(match[1]);
        if (match[2]) end = Math.min(end, Number(match[2]));
      }
    } else start = NaN;
    if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start < 0 || start > end || start >= blob.size) {
      headers.set('Content-Range', `bytes */${blob.size}`);
      headers.set('Content-Length', '0');
      return new Response(null, { status: 416, headers });
    }
    headers.set('Content-Range', `bytes ${start}-${end}/${blob.size}`);
    headers.set('Content-Length', String(end - start + 1));
    return new Response(blob.slice(start, end + 1), { status: 206, headers });
  }
  // Native downloads use the loopback proxy, which returns readable audio even
  // when the reciter's host does not support browser CORS. Network fetches made
  // by this worker are not intercepted by itself.
  if (self.location.hostname === '127.0.0.1' || self.location.hostname === 'localhost') {
    return fetch(request);
  }
  return fetch(sourceUrl, { headers: request.headers });
}

function notifyQcf4OfflineStatus(client, status, completed = 0, total = qcf4OfflineUrls.length, error = '') {
  client?.postMessage?.({ type: 'QCF4_1441_OFFLINE_STATUS', status, completed, total, error });
}

async function cacheQcf4OfflineAssets(client) {
  // The native server serves these pages and fonts from the installed package.
  // Report them ready without copying the entire Mushaf into Cache Storage.
  if (NATIVE_BUNDLED_ORIGIN) {
    qcf4CacheState = { status: 'ready', completed: qcf4OfflineUrls.length, error: '' };
    notifyQcf4OfflineStatus(client, 'ready', qcf4OfflineUrls.length);
    return;
  }
  const cache = await caches.open(QCF4_OFFLINE_CACHE_NAME);
  const cachedRequests = await cache.keys();
  const cachedUrls = new Set(cachedRequests.map((request) => request.url));
  let completed = qcf4OfflineUrls.reduce((count, url) => count + Number(cachedUrls.has(new URL(url, self.location.origin).href)), 0);
  qcf4CacheState = { status: 'caching', completed, error: '' };

  if (completed === qcf4OfflineUrls.length) {
    qcf4CacheState = { status: 'ready', completed, error: '' };
    notifyQcf4OfflineStatus(client, 'ready', completed);
    return;
  }

  notifyQcf4OfflineStatus(client, 'caching', completed);
  let failures = 0;
  // تسلسل متعمد: أكثر استقراراً على Android، ويمنع إيقاف تنزيل بقية المصحف إذا أخفق مورد مؤقتاً.
  for (const url of qcf4OfflineUrls) {
    if (cachedUrls.has(new URL(url, self.location.origin).href)) continue;
    try {
      const response = await fetch(url);
      if (!response || !response.ok) throw new Error(`تعذر تخزين أصل مصحف 1441 (${response?.status ?? 'network'}).`);
      await cache.put(url, response);
      completed += 1;
    qcf4CacheState = { status: 'caching', completed, error: '' };
    notifyQcf4OfflineStatus(client, 'caching', completed);
    } catch {
      failures += 1;
    }
  }

  if (failures > 0) throw new Error(`تعذر تخزين ${failures} من أصول مصحف 1441؛ سيستأنف التنزيل عند توفر الاتصال.`);

  qcf4CacheState = { status: 'ready', completed, error: '' };
  notifyQcf4OfflineStatus(client, 'ready', completed);
}

function beginQcf4OfflineCache(client) {
  if (!qcf4PrecachePromise) {
    qcf4PrecachePromise = cacheQcf4OfflineAssets(client).catch((cause) => {
      qcf4CacheState = {
        status: 'error',
        completed: qcf4CacheState.completed,
        error: cause instanceof Error ? cause.message : 'تعذر تجهيز المصحف دون اتصال.',
      };
      qcf4PrecachePromise = null;
      notifyQcf4OfflineStatus(client, 'error', qcf4CacheState.completed, qcf4OfflineUrls.length, qcf4CacheState.error);
    });
  } else {
    notifyQcf4OfflineStatus(client, qcf4CacheState.status, qcf4CacheState.completed, qcf4OfflineUrls.length, qcf4CacheState.error);
  }
  return qcf4PrecachePromise;
}

/**
 * يبقى فتح التطبيق CacheFirst كي لا يتأخر أو يتعطل دون اتصال، لكن الغلاف نفسه
 * يُحدّث في الخلفية عند أي فتح متصل. بهذا لا تستقر واجهة رأس قديمة في PWA.
 */
async function refreshAppShellInBackground() {
  const response = await fetch('/index.html', { cache: 'no-store' });
  if (!response?.ok) throw new Error(`تعذر تحديث غلاف التطبيق (${response?.status ?? 'network'}).`);
  const cache = await caches.open(CACHE_NAME);
  const previous = await cache.match('/index.html');
  const [freshSource, previousSource] = await Promise.all([
    response.clone().text(),
    previous?.clone().text() ?? Promise.resolve(''),
  ]);
  await Promise.all([
    cache.put('/index.html', response.clone()),
    cache.put('/', response.clone()),
  ]);
  // عند وصول غلاف أحدث أخبر الصفحة المفتوحة كي تعيد التحميل فوراً بدلاً من انتظار فتح تالٍ.
  if (freshSource !== previousSource) {
    const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    windows.forEach((client) => client.postMessage({ type: 'APP_SHELL_UPDATED' }));
  }
}

// ─── Fetch ──────────────────────────────────────────────────────────────────
self.addEventListener('fetch', (event) => {
  const url = new URL(event.request.url);

  // تلاوات القرآن التي نزلها المستخدم: CacheFirst من التخزين المحلي، ثم المصدر عند توفر الشبكة.
  if (url.pathname === QURAN_RECITER_OFFLINE_PLAYBACK_PATH) {
    const sourceUrl = url.searchParams.get('source');
    if (!sourceUrl) return;
    event.respondWith(serveQuranReciterAudio(sourceUrl, event.request));
    return;
  }

  // Cross-origin reciter media must stay on WebKit's native media path. In the
  // iOS app the document itself lives on 127.0.0.1; routing a live MP3 through
  // this Service Worker adds another loopback/service-worker lifecycle that can
  // be suspended during lock-screen/background transitions. Returning without
  // respondWith() lets WebKit perform the media request directly (including byte
  // ranges). Same-origin offline playback still goes through the cache path above.
  if (url.origin !== self.location.origin &&
      (event.request.destination === 'audio' || /\.(?:mp3|m4a|aac|ogg|oga|wav)(?:$|[?#])/i.test(url.href))) {
    return;
  }

  // تجاهل طلبات non-GET
  if (event.request.method !== 'GET') return;

  // Optional tafsir is online until explicitly downloaded into IndexedDB.
  // Never retain its responses/packages as a second Service Worker copy.
  if (url.pathname.startsWith('/api/quran/tafsir/')) return;

  // Fonts and page data already exist offline in both native packages. Let the
  // loopback server read them directly, including after installing an update.
  // Every native asset is already packaged and served offline by the local
  // server. Read this build's bytes so a cached older script cannot override an
  // installed app update. Public web/PWA requests keep their existing caching.
  if (NATIVE_BUNDLED_ORIGIN && (url.pathname.startsWith('/assets/') || isQcf4OfflineAsset(url))) return;

  // ملف الأذان الذي يرفعه المدير: CacheFirst ليعمل بعد أن ينزل مرة واحدة على الجهاز.
  if (isPublishedAdhanAudioRequest(url)) {
    event.respondWith(
      caches.open(ADHAN_AUDIO_CACHE_NAME).then((cache) => cache.match(event.request).then((cached) => {
        if (cached) return cached;
        return fetch(event.request).then((response) => {
          if (response && response.ok) void cache.put(event.request, response.clone()).catch(() => undefined);
          return response;
        });
      }))
    );
    return;
  }

  // ─── تفسير قارئ 1441 — CacheFirst لفتحه فوراً بعد حفظه محلياً ────────────
  if (isQcf4TafsirRequest(url)) {
    event.respondWith(
      caches.open(QCF4_TAFSIR_CACHE_NAME).then((cache) => cache.match(event.request).then((cached) => {
        if (cached) return cached;
        return fetch(event.request).then((response) => {
          if (response && response.ok) void cache.put(event.request, response.clone()).catch(() => undefined);
          return response;
        });
      }))
    );
    return;
  }

  // ─── قائمة القراء — NetworkFirst حتى تنعكس الإضافة/التعديل/الحذف، مع آخر نسخة للعمل دون اتصال ───
  if (url.pathname === QURAN_RECITER_CATALOG_URL) {
    event.respondWith(
      caches.open(QCF4_OFFLINE_CACHE_NAME).then(async (cache) => {
        try {
          const response = await fetch(event.request, { cache: 'no-store' });
          if (response && response.ok) {
            await cache.put(event.request, response.clone()).catch(() => undefined);
            return response;
          }
          const cached = await cache.match(event.request);
          return cached || response;
        } catch (error) {
          const cached = await cache.match(event.request);
          if (cached) return cached;
          throw error;
        }
      })
    );
    return;
  }

  // ─── فهرس البحث والانتقال — CacheFirst ليستمر البحث دون اتصال ──────────
  if (isQcf4NavigationRequest(url)) {
    event.respondWith(
      caches.open(QCF4_OFFLINE_CACHE_NAME).then((cache) => cache.match(event.request).then((cached) => {
        if (cached) return cached;
        return fetch(event.request).then((response) => {
          if (response && response.ok) void cache.put(event.request, response.clone()).catch(() => undefined);
          return response;
        });
      }))
    );
    return;
  }

  // تخدم أيقونات غلاف التطبيق من كاش الواجهة كي تبقى ظاهرة دون اتصال.
  if (APP_SHELL_URLS.includes(url.pathname) && event.request.mode !== 'navigate') {
    event.respondWith(
      caches.match(event.request).then((cached) => cached || fetch(event.request))
    );
    return;
  }

  // ─── معاينة مصحف المدينة 1441 — CacheFirst مخصص للعمل دون اتصال ──────────
  if (isQcf4OfflineAsset(url)) {
    event.respondWith(
      caches.open(QCF4_OFFLINE_CACHE_NAME).then((cache) => cache.match(event.request).then((cached) => {
        if (cached) return cached;
        return fetch(event.request).then((response) => {
          if (response && response.ok) void cache.put(event.request, response.clone()).catch(() => undefined);
          return response;
        });
      }))
    );
    return;
  }

  // تجاهل طلبات API والـ storage الأخرى — تحتاج شبكة دائماً.
  // يجب أن يأتي هذا بعد مسارات QCF4 المحلية أعلاه كي تُقرأ من الكاش دون اتصال.
  if (url.pathname.startsWith('/api/') || url.pathname.startsWith('/manus-storage/')) return;

  // تجاهل chrome-extension وغيرها
  if (!url.protocol.startsWith('http')) return;

  // رابط الويدجت في Android يحمل معرف الجهاز للمزامنة عندما يكون متصلاً، لكن لا يجوز
  // أن يتحول هذا الرابط إلى طلب شبكة عند البدء دون اتصال. أعد الغلاف المحفوظ مباشرة.
  if (event.request.mode === 'navigate' && url.searchParams.has('native_widget_id')) {
    event.respondWith(
      caches.match('/index.html').then((cached) => cached || caches.match('/')).then((cached) => cached || fetch('/index.html'))
    );
    return;
  }

  // لا نعيد /app من غلاف التطبيق المخزن: يظل تحويل الخادم حسب الجهاز هو المصدر.
  // هذه الحماية مهمة للغلاف القديم في Safari وPWA حتى لا يعرض صفحة 404 داخلية.
  if (event.request.mode === 'navigate' && url.pathname === '/app') {
    event.respondWith(fetch(event.request, { cache: 'no-store' }));
    return;
  }

  // ─── Navigation (HTML) — App shell CacheFirst ────────────────────────────
  // لا ننتظر مهلة الشبكة في Android: الغلاف المحفوظ يفتح فوراً، ويصل التحديث
  // عبر إصدار عامل الخدمة التالي لا عبر حجب شاشة البداية.
  if (event.request.mode === 'navigate') {
    // Native loopback is always reachable even when the phone is offline. Fetch the
    // packaged HTML first so an installed app update can never be hidden by an older
    // Service Worker shell. On the public web, fall back to the current cache offline.
    event.respondWith(
      fetch(event.request, { cache: 'no-store' }).then((response) => {
        if (response && response.ok) {
          const cloneA = response.clone();
          const cloneB = response.clone();
          void caches.open(CACHE_NAME).then((cache) => Promise.all([
            cache.put('/index.html', cloneA),
            cache.put('/', cloneB),
          ])).catch(() => undefined);
        }
        return response;
      }).catch(() => caches.open(CACHE_NAME).then((cache) =>
        cache.match('/index.html').then((cached) => cached || cache.match('/'))
      ).then((cached) => cached || caches.match('/index.html')).then((cached) => cached || caches.match('/')))
    );
    return;
  }

  // ─── JS / CSS — CacheFirst للـ assets المُهشَّشة (Vite يضيف hash للأسماء) ─────
  // الـ assets في /assets/ لها hash في الاسم → آمن استخدام CacheFirst
  // هذا يضمن عمل الـ chunks الضخمة (مثل mutoon.ts) offline بدون تأخير
  if (url.pathname.startsWith('/assets/')) {
    event.respondWith(
      caches.match(event.request).then((cached) => {
        if (cached) return cached;
        // بعد تحديث التطبيق قد يبقى فهرس قديم يشير إلى اسم حزمة قرآن ممهّش سابق.
        // أعد الحزمة المطابقة المخزنة حالياً كي يفتح القارئ بدلاً من فشل dynamic import.
        if (isQuranReaderChunk(url)) {
          return caches.open(CACHE_NAME).then(async (cache) => {
            const currentChunk = await matchCurrentQuranReaderChunk(cache);
            if (currentChunk) return currentChunk;
            return fetch(event.request).then((response) => {
              if (response && response.status === 200) void cache.put(event.request, response.clone());
              return response;
            });
          });
        }
        // غير موجود في الكاش — جلبه من الشبكة وتخزينه
        return fetch(event.request).then((response) => {
          if (response && response.status === 200) {
            const clone = response.clone();
            caches.open(CACHE_NAME).then((cache) => cache.put(event.request, clone));
          }
          return response;
        });
      })
    );
    return;
  }

  // ─── Quiz Data JSON — CacheFirst ─────────────────────────────────────────
  if (url.pathname.startsWith("/quiz-data/")) {
    event.respondWith(
      caches.match(event.request).then((cached) => {
        if (cached) return cached;
        return fetch(event.request).then((response) => {
          if (response && response.status === 200) {
            const clone = response.clone();
            caches.open(CACHE_NAME).then((cache) => cache.put(event.request, clone));
          }
          return response;
        });
      })
    );
    return;
  }

  // ─── JS / CSS غير مُهشَّشة — NetworkFirst ────────────────────────────────
  if (url.pathname.match(/\.(js|css|mjs)$/)) {
    event.respondWith(
      networkFirstWithTimeout(event.request, NETWORK_TIMEOUT_MS).catch(() => {
        return caches.match(event.request);
      })
    );
    return;
  }

  // ─── Static assets (صور، خطوط) — CacheFirst ─────────────────────────────
  // هذه الملفات نادراً ما تتغير، الكاش أسرع
  if (url.pathname.match(/\.(woff2|woff|ttf|png|jpg|jpeg|svg|ico|webp)$/)) {
    event.respondWith(
      caches.match(event.request).then((cached) => {
        if (cached) return cached;
        return fetch(event.request).then((response) => {
          if (response && response.status === 200) {
            const clone = response.clone();
            caches.open(CACHE_NAME).then((cache) => cache.put(event.request, clone));
          }
          return response;
        });
      })
    );
    return;
  }

  // ─── باقي الطلبات — NetworkFirst ─────────────────────────────────────────
  event.respondWith(
    networkFirstWithTimeout(event.request, NETWORK_TIMEOUT_MS).catch(() => {
      return caches.match(event.request);
    })
  );
});

// إشعار Web Push يجب أن يكون ظاهراً فور وصوله، ولا يشغّل ملف صوت مخصصاً.
self.addEventListener('push', (event) => {
  let payload = {};
  try { payload = event.data ? event.data.json() : {}; } catch { payload = {}; }
  const title = typeof payload.title === 'string' ? payload.title : 'حان وقت الصلاة';
  const body = typeof payload.body === 'string' ? payload.body : 'حان وقت الصلاة';
  event.waitUntil(self.registration.showNotification(title, {
    body,
    icon: '/icon-192.png',
    badge: '/icon-192.png',
    tag: typeof payload.tag === 'string' ? payload.tag : 'munibin-prayer',
    data: { url: typeof payload.url === 'string' ? payload.url : '/prayer-times' },
  }));
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const targetUrl = event.notification.data?.url || '/prayer-times';
  event.waitUntil(clients.matchAll({ type: 'window', includeUncontrolled: true }).then((windows) => {
    const existing = windows.find((client) => new URL(client.url).origin === self.location.origin);
    return existing ? existing.focus() : clients.openWindow(targetUrl);
  }));
});

// ─── رسالة من التطبيق: أعد تحميل الصفحة بعد تفعيل SW الجديد ───────────────
self.addEventListener('message', (event) => {
  if (event.data && event.data.type === 'SKIP_WAITING') {
    self.skipWaiting();
  }
  if (event.data && event.data.type === 'CACHE_QCF4_1441') {
    event.waitUntil(beginQcf4OfflineCache(event.source));
  }
  if (event.data && event.data.type === 'CACHE_QCF4_STARTUP') {
    event.waitUntil(cacheQcf4StartupAssets());
  }
  if (event.data && event.data.type === 'CACHE_READING_ASSETS') {
    event.waitUntil(beginReaderAssetCache());
  }
  if (event.data && event.data.type === 'CACHE_QURAN_READER_ASSETS') {
    event.waitUntil(beginQuranReaderAssetCache());
  }
});
