'use strict';
const scope = new URL(self.registration.scope);
const base = new URL('../', scope);
const cacheName = 'haven-push:' + base.pathname + 'state';
const stateUrl = new URL('state', scope).href;
self.addEventListener('install', event => event.waitUntil(self.skipWaiting()));
self.addEventListener('activate', event => event.waitUntil(self.clients.claim()));
self.addEventListener('push', event => event.waitUntil((async () => {
  const cache = await caches.open(cacheName);
  const response = await cache.match(stateUrl);
  const state = response ? await response.json() : {};
  let message;
  try { message = event.data.json(); } catch { return; }
  if (!state.active || state.profileId !== message.profileId || !/^[a-f0-9-]{36}$/.test(message.notificationId)) return;
  await self.registration.showNotification('报修待处理', {
    body: '有报修事项需要处理，请打开查看。', tag: 'haven-' + message.notificationId,
    data: { notificationId: message.notificationId },
  });
})()));
self.addEventListener('notificationclick', event => {
  event.notification.close();
  event.waitUntil((async () => {
    const id = event.notification.data?.notificationId;
    if (!/^[a-f0-9-]{36}$/.test(id || '')) return;
    const url = new URL(base.href);
    if (base.pathname === '/admin/') url.searchParams.set('notification', id);
    else url.hash = '/notifications/' + id;
    const clients = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    const client = clients.find(item => new URL(item.url).pathname === base.pathname);
    if (client) {
      await client.focus();
      client.postMessage({ type: 'haven-notification', notificationId: id });
    } else await self.clients.openWindow(url.href);
  })());
});
