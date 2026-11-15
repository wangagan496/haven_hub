import type { TestContext } from 'node:test';
import assert from 'node:assert/strict';
import sharp from 'sharp';
import { createApp } from '../../src/app.js';
import { readConfig } from '../../src/config.js';

export type Envelope = { code: number; data: any; message: string };

export async function fixture(t: TestContext, path = ':memory:', now: () => number = () => Date.parse('2026-10-17T00:00:00Z')) {
  const config = { ...readConfig({}), databasePath: path };
  const logs: object[] = [];
  const { app, store } = createApp(config, { now, log: event => logs.push(event) });
  const server = app.listen(0, '127.0.0.1');
  await new Promise<void>(resolve => server.once('listening', resolve));
  const address = server.address();
  assert(address && typeof address !== 'string');
  const base = `http://127.0.0.1:${address.port}`;
  let closed = false;
  async function close() {
    if (closed) return;
    closed = true;
    await new Promise<void>((resolve, reject) => {
      server.close(error => error ? reject(error) : resolve());
      server.closeIdleConnections();
    });
    store.close();
  }
  t.after(close);
  async function request(method: string, path: string, token?: string, body?: unknown) {
    const response = await fetch(base + path, { method, headers: {
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...(body === undefined ? {} : { 'Content-Type': 'application/json' }),
    }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
    return { status: response.status, ...(await response.json() as Envelope) };
  }
  async function login(mobile = '13800138000') {
    const code = await request('GET', `/code?mobile=${mobile}`);
    assert.equal(code.code, 10000);
    assert.equal(code.data.development, true);
    const login = await request('POST', '/login', undefined, { mobile, code: code.data.code });
    assert.equal(login.code, 10000);
    if (['13800138091','13800138092'].includes(mobile)) {
      const id = String(store.one('SELECT id FROM users WHERE mobile=?', mobile)!.id);
      store.run("INSERT OR IGNORE INTO worker_skills(workerId,skill) VALUES (?,'plumbing')", id);
    }
    return login.data as { token: string; refreshToken: string };
  }
  async function upload(token: string) {
    const image = await sharp({ create: { width: 8, height: 8, channels: 3, background: '#7654a1' } }).png().toBuffer();
    const form = new FormData();
    form.append('file', new Blob([new Uint8Array(image)]), 'example.png');
    const response = await fetch(base + '/upload', { method: 'POST', headers: { Authorization: `Bearer ${token}` }, body: form });
    const body = await response.json() as Envelope;
    assert.equal(body.code, 10000);
    return String(body.data.url);
  }
  const roomBody = (url: string) => ({ point: '学习小区', building: '1栋', room: '101', name: '张三', gender: 1,
    mobile: '13800138000', idcardFrontUrl: url, idcardBackUrl: url });
  async function room(token: string) {
    const url = await upload(token);
    const body = roomBody(url);
    const response = await request('POST', '/room', token, body);
    assert.equal(response.code, 10000);
    assert.equal(response.data.complete, true);
    return { record: response.data.rows[0], body };
  }
  return { base, config, store, request, login, upload, room, roomBody, logs, close };
}
