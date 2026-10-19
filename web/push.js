/* Shared by Flutter Web and the property desk. No authentication tokens are stored here. */
(() => {
  'use strict';
  const base = new URL('./', document.baseURI);
  const prefix = 'haven-push:' + base.pathname;
  const scope = new URL('push/', base);
  const stateUrl = new URL('state', scope).href;
  const cacheName = prefix + 'state';
  let pendingClick = '';
  const supported = () => window.isSecureContext && 'serviceWorker' in navigator && 'PushManager' in window && 'Notification' in window;
  function installation() {
    let id = localStorage.getItem(prefix + ':installation');
    if (!id) {
      id = Array.from(crypto.getRandomValues(new Uint8Array(32)), byte => byte.toString(16).padStart(2, '0')).join('');
      localStorage.setItem(prefix + ':installation', id);
    }
    return id;
  }
  async function registration() {
    const reg = await navigator.serviceWorker.register(new URL('sw.js', scope).href, { scope: scope.href });
    if (!reg.active) {
      const worker = reg.installing || reg.waiting;
      if (worker) await new Promise((resolve, reject) => {
        const timer = setTimeout(() => reject(Error('通知服务启动超时，请重试')), 10000);
        worker.addEventListener('statechange', () => {
          if (worker.state === 'activated') { clearTimeout(timer); resolve(); }
          if (worker.state === 'redundant') { clearTimeout(timer); reject(Error('通知服务初始化失败')); }
        });
      });
    }
    return reg;
  }
  async function saveState(value) {
    const cache = await caches.open(cacheName);
    await cache.put(stateUrl, new Response(JSON.stringify(value), { headers: { 'Content-Type': 'application/json' } }));
  }
  async function disable() {
    pendingClick = '';
    localStorage.removeItem(prefix + ':enabled');
    if (!supported()) return { supported: false };
    await saveState({ active: false });
    const reg = await navigator.serviceWorker.getRegistration(scope.href);
    if (reg) {
      for (const note of await reg.getNotifications()) note.close();
      const sub = await reg.pushManager.getSubscription();
      if (sub && !(await sub.unsubscribe())) throw Error('浏览器订阅解绑未完成，请重试');
    }
    return { installationId: installation(), disabled: true };
  }
  window.havenPush = async raw => {
    try {
      const request = JSON.parse(raw);
      if (request.action === 'takeClick') { const id = pendingClick; pendingClick = ''; return JSON.stringify({ notificationId: id }); }
      if (request.action === 'disable') return JSON.stringify(await disable());
      if (!supported()) throw Error('当前环境不支持系统推送，请使用 HTTPS 或本机 localhost 的 Edge');
      if (request.action === 'requestPermission') {
        if (await Notification.requestPermission() !== 'granted') throw Error('系统通知未获授权，可在浏览器设置中开启；待办仍会保留');
        return '{}';
      }
      if (request.action === 'status') return JSON.stringify({ supported: true, permission: Notification.permission, enabled: localStorage.getItem(prefix + ':enabled') === 'true' });
      if (request.action === 'resume' && (localStorage.getItem(prefix + ':enabled') !== 'true' || Notification.permission !== 'granted')) return '{}';
      if (request.action === 'enable') {
        const permission = await Notification.requestPermission();
        if (permission !== 'granted') throw Error('系统通知未获授权，可在浏览器设置中开启；待办仍会保留');
      }
      const reg = await registration();
      let sub = await reg.pushManager.getSubscription();
      const encoded = request.publicKey.replace(/-/g, '+').replace(/_/g, '/');
      const key = Uint8Array.from(atob(encoded + '='.repeat((4 - encoded.length % 4) % 4)), char => char.charCodeAt(0));
      if (sub && sub.options.applicationServerKey && Array.from(new Uint8Array(sub.options.applicationServerKey)).join() !== Array.from(key).join()) {
        if (!(await sub.unsubscribe())) throw Error('旧浏览器订阅解绑未完成，请重试');
        sub = null;
      }
      if (!sub) {
        try { sub = await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: key }); }
        catch (error) {
          if (error.name === 'NotAllowedError' || /permission denied/i.test(error.message || '')) throw Error('浏览器拒绝推送订阅，请检查站点通知权限和浏览器策略；待办仍会保留');
          throw Error('浏览器推送订阅未成功，请检查网络或浏览器设置后重试；待办仍会保留');
        }
      }
      localStorage.setItem(prefix + ':enabled', 'true');
      await saveState({ active: true, profileId: request.profileId, base: base.href });
      const json = sub.toJSON();
      return JSON.stringify({ platform: 'web', installationId: installation(), subscription: {endpoint:json.endpoint,keys:json.keys} });
    } catch (error) { return JSON.stringify({ error: error.message || '系统推送操作失败，请重试' }); }
  };
  if ('serviceWorker' in navigator) navigator.serviceWorker.addEventListener('message', event => {
    if (event.data && event.data.type === 'haven-notification' && /^[a-f0-9-]{36}$/.test(event.data.notificationId)) {
      pendingClick = event.data.notificationId;
      window.dispatchEvent(new CustomEvent('haven-notification', { detail: pendingClick }));
    }
  });
})();
