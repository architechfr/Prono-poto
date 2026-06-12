/* Prono Poto — service worker minimal.
   But : rendre l'app installable (vrai plein écran sans barre d'adresse sur
   Android via WebAPK) + dispo hors-ligne, SANS jamais servir une version périmée.
   Stratégie : "network-first" sur les fichiers de l'app (HTML), repli cache si
   hors-ligne. On n'intercepte JAMAIS les autres domaines (Supabase, CDN,
   flagcdn, football-data…) → les données live passent toujours par le réseau. */
const CACHE = "pp-shell-v1";

self.addEventListener("install", (e) => { self.skipWaiting(); });

self.addEventListener("activate", (e) => {
  e.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", (e) => {
  const req = e.request;
  if (req.method !== "GET") return;                 // jamais les écritures
  const url = new URL(req.url);
  if (url.origin !== location.origin) return;       // Supabase / CDN / API → réseau direct

  // App shell : on tente le réseau (toujours la dernière version), repli cache hors-ligne.
  e.respondWith(
    fetch(req)
      .then((res) => {
        const copy = res.clone();
        caches.open(CACHE).then((c) => c.put(req, copy)).catch(() => {});
        return res;
      })
      .catch(() => caches.match(req).then((m) => m || caches.match("./")))
  );
});
