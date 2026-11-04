// Android shares into this page by opening it with the link in its address (?url=…). The worker
// answers those from a copy of the page kept on the phone, so shared links never reach the
// website's server. Installing the page with this worker is also what puts it in the Share menu.
const version = 'send-1';

self.addEventListener('install', event => {
  event.waitUntil(caches.open(version).then(cache => cache.add('./')).then(() => self.skipWaiting()));
});

self.addEventListener('activate', event => {
  event.waitUntil(caches.keys()
    .then(keys => Promise.all(keys.filter(key => key !== version).map(key => caches.delete(key))))
    .then(() => self.clients.claim()));
});

self.addEventListener('fetch', event => {
  const url = new URL(event.request.url);
  if (event.request.mode !== 'navigate' || !url.search) return;
  // Without the saved copy, fetch the page without its address's query, which holds the link.
  event.respondWith(caches.match('./').then(page => page || fetch(url.origin + url.pathname)));
});
