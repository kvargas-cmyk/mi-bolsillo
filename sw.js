const CACHE = 'mi-bolsillo-shell-v3-4';
const SHELL = ['./','./index.html','./manifest.webmanifest','./icon-192.png','./icon-512.png'];
self.addEventListener('install',event=>{
  event.waitUntil(caches.open(CACHE).then(cache=>cache.addAll(SHELL)).then(()=>self.skipWaiting()));
});
self.addEventListener('activate',event=>{
  event.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(k=>k.startsWith('mi-bolsillo-shell-')&&k!==CACHE).map(k=>caches.delete(k)))).then(()=>self.clients.claim()));
});
self.addEventListener('fetch',event=>{
  const req=event.request;
  if(req.method!=='GET')return;
  const url=new URL(req.url);
  if(url.origin!==self.location.origin || url.pathname.endsWith('/config.js'))return;
  if(req.mode==='navigate'){
    event.respondWith(fetch(req).catch(()=>caches.match('./index.html')));
    return;
  }
  if(/\.(png|webmanifest)$/.test(url.pathname)){
    event.respondWith(caches.match(req).then(cached=>cached||fetch(req)));
  }
});
