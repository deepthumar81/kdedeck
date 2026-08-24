// Cache version - bump this whenever files are updated
const CACHE_NAME = 'kdedeck-v3';
const ASSETS = [
  '/',
  '/index.html',
  '/css/style.css',
  '/js/app.js',
  '/js/icons.js',
  '/manifest.json'
];

// On install: cache all static assets
self.addEventListener('install', (e) => {
  self.skipWaiting(); // Activate immediately, don't wait
  e.waitUntil(
    caches.open(CACHE_NAME).then((cache) => cache.addAll(ASSETS))
  );
});

// On activate: delete old caches
self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter(k => k !== CACHE_NAME).map(k => caches.delete(k)))
    ).then(() => self.clients.claim())
  );
});

// On fetch: always try network first, fall back to cache
// Never cache /ws or /api/ routes
self.addEventListener('fetch', (e) => {
  const url = e.request.url;
  if (url.includes('/ws') || url.includes('/api/')) return;

  e.respondWith(
    fetch(e.request)
      .then(res => {
        // Update cache with fresh response
        const clone = res.clone();
        caches.open(CACHE_NAME).then(cache => cache.put(e.request, clone));
        return res;
      })
      .catch(() => caches.match(e.request))
  );
});
