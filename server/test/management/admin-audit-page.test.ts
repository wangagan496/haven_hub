import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';

class Element {
  value = ''; textContent = ''; disabled = false; hidden = false;
  children: Element[] = []; onclick?: () => void; onsubmit?: (event: any) => void;
  append(...items: Element[]) { this.children.push(...items); }
  replaceChildren(...items: Element[]) { this.children = items; }
  querySelectorAll() { return [] as Element[]; }
}
function page() {
  let token: string | null = 'first-session';
  const ids = ['audit-rows','audit-status','audit-more','audit-filters','audit-reset','actorId','targetId','targetType','action'];
  const elements = Object.fromEntries(ids.map(id => [id, new Element()]));
  elements['audit-filters']!.querySelectorAll = () => ids.filter(id => ['actorId','targetId','targetType','action'].includes(id)).map(id => elements[id]!);
  const handlers: Record<string, () => void> = {};
  const requests: { url: string; resolve: (response: any) => void; reject: (error: Error) => void }[] = [];
  runInNewContext(readFileSync(new URL('../../public/admin/audit.js', import.meta.url), 'utf8'), {
    document: { getElementById: (id: string) => elements[id], createElement: () => new Element() },
    sessionStorage: { getItem: () => token, removeItem: () => { token = null; } },
    window: { addEventListener: (name: string, handler: () => void) => { handlers[name] = handler; } },
    fetch: (url: string) => new Promise((resolve, reject) => requests.push({ url, resolve, reject })), URLSearchParams,
  });
  const tick = () => new Promise(resolve => setImmediate(resolve));
  return { elements, requests, tick, session: (next: string | null) => { token = next; handlers.pageshow!(); },
    query: () => elements['audit-filters']!.onsubmit!({ preventDefault() {} }),
    respond: async (index: number, rows: any[], nextCursor: number | null = null, status = 200) => {
      requests[index]!.resolve({ ok: status === 200, status, headers: { get: () => '' }, json: async () => ({ code: 10000, data: { rows, nextCursor } }) });
      await tick();
    } };
}
const row = (seq: number) => ({ seq, actorId: '<img src=x onerror=alert(1)>', actorRole: 'admin', targetType: 'repair', targetId: 'repair-1', action: 'repair.note', source: 'live', before: null, after: { revision: seq } });

test('audit pagination retains applied filters and existing rows on a retryable failure', async () => {
  const p = page();
  await p.respond(0, [row(5)], 5);
  p.elements.actorId!.value = 'new-filter-not-submitted';
  p.elements['audit-more']!.onclick!();
  assert.equal(new URL(p.requests[1]!.url, 'https://local').searchParams.get('actorId'), null);
  p.requests[1]!.reject(Error('offline')); await p.tick();
  assert.equal(p.elements['audit-rows']!.children.length, 1);
  assert.equal(p.elements['audit-more']!.disabled, false);
  p.elements['audit-more']!.onclick!(); await p.respond(2, [row(4)]);
  assert.equal(p.elements['audit-rows']!.children.length, 2);
  p.query();
  assert.equal(new URL(p.requests[3]!.url, 'https://local').searchParams.get('actorId'), 'new-filter-not-submitted');
  await p.respond(3, []);
  assert.match(p.elements['audit-status']!.textContent, /没有符合/);
});

test('old session responses cannot display data or unlock a newer in-flight query', async () => {
  const p = page();
  p.session('second-session'); p.query();
  await p.respond(0, [row(5)], null, 401);
  assert.equal(p.elements['audit-rows']!.children.length, 0);
  assert.equal(p.elements.actorId!.disabled, true);
  await p.respond(1, [row(6)]);
  assert.equal(p.elements['audit-rows']!.children.length, 1);
  assert.equal(p.elements.actorId!.disabled, false);
  p.session(null);
  assert.equal(p.elements['audit-rows']!.children.length, 0);
  assert.match(p.elements['audit-status']!.textContent, /登录/);
});

test('expired session clears displayed audit data and renders identifiers as literal text', async () => {
  const p = page();
  await p.respond(0, [row(5)]);
  assert.match(p.elements['audit-rows']!.children[0]!.children[1]!.textContent, /<img src=x onerror=alert\(1\)>/);
  p.query(); await p.respond(1, [], null, 401);
  assert.equal(p.elements['audit-rows']!.children.length, 0);
  assert.equal(p.elements.actorId!.disabled, false);
  assert.match(p.elements['audit-status']!.textContent, /登录/);
});
