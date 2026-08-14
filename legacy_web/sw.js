const CACHE_NAME = "obf-pwa-v3";
const APP_SHELL = new URL("./index.html", self.registration.scope).href;
const SUPABASE_SDK = "https://unpkg.com/@supabase/supabase-js@2";
const CORE_ASSETS = ["./", "./index.html", "./style.css", "./app.js", "./api.js", SUPABASE_SDK];

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => cache.addAll(CORE_ASSETS))
  );
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) =>
        Promise.all(keys.map((k) => (k !== CACHE_NAME ? caches.delete(k) : null)))
      )
  );
  self.clients.claim();
});

self.addEventListener("fetch", (event) => {
  const req = event.request;
  if (req.mode === "navigate") {
    event.respondWith(fetch(req).catch(() => caches.match(APP_SHELL)));
    return;
  }
  const isAppAsset = new URL(req.url).origin === location.origin;
  if (req.method === "GET" && (isAppAsset || req.url === SUPABASE_SDK)) {
    event.respondWith(
      caches.match(req).then((cached) => {
        const network = fetch(req)
          .then((resp) => {
            if (resp && resp.status === 200) {
              const clone = resp.clone();
              caches.open(CACHE_NAME).then((cache) => cache.put(req, clone));
            }
            return resp;
          })
          .catch(() => cached || (isAppAsset ? caches.match(APP_SHELL) : undefined));
        return cached || network;
      })
    );
  }
});

self.addEventListener("sync", (event) => {
  if (event.tag === "sync-ops") {
    event.waitUntil(
      self.clients.matchAll({ includeUncontrolled: true }).then((clients) => {
        clients.forEach((c) => c.postMessage({ type: "sync" }));
      })
    );
  }
});
