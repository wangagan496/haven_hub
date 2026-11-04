import test from 'node:test';
import assert from 'node:assert/strict';
import { gzipSync } from 'node:zlib';
import { request as httpRequest } from 'node:http';
import sharp from 'sharp';
import { fixture } from './repair-fixture.js';

test('compressed JSON updates a profile through the authenticated HTTP path', async t => {
  const f = await fixture(t);
  const response = await fetch(f.base + '/userInfo', {
    method: 'PUT', headers: { Authorization: `Bearer ${f.tokens.resident}`, 'Content-Type': 'application/json', 'Content-Encoding': 'gzip' },
    body: new Uint8Array(gzipSync(JSON.stringify({ nickName: '压缩请求', avatar: '' }))), signal: AbortSignal.timeout(3000),
  });
  assert.equal(response.status, 200);
  assert.equal((await response.json() as { code: number }).code, 10000);
  assert.equal((await f.call('resident', 'GET', '/userInfo')).nickName, '压缩请求');
});

test('invalid compressed JSON is a client error and the server remains usable', async t => {
  const f = await fixture(t);
  const payloads = [
    Buffer.from('not-a-gzip-stream'),
    Buffer.concat([gzipSync('{}'), Buffer.from('invalid-trailing-bytes')]),
    gzipSync(Buffer.from('{invalid-json')),
  ];
  for (const body of payloads) {
    const response = await fetch(f.base + '/login', {
      method: 'POST', headers: { 'Content-Type': 'application/json', 'Content-Encoding': 'gzip' },
      body: new Uint8Array(body), signal: AbortSignal.timeout(3000),
    });
    assert.equal(response.status, 400);
    const result = await response.json() as { code: number; message: string };
    assert.equal(result.code, 40000);
    assert.doesNotMatch(result.message, /Z_DATA_ERROR|stack|invalid-trailing/);
    assert.equal((await fetch(f.base + '/health', { signal: AbortSignal.timeout(3000) })).status, 200);
  }
});

test('JSON limit applies after decompression and unsupported encodings are rejected', async t => {
  const f = await fixture(t);
  const large = gzipSync(JSON.stringify({ padding: 'x'.repeat(140 * 1024) }));
  assert(large.length < 1024, 'small compressed request expands past the JSON limit');
  const response = await fetch(f.base + '/login', {
    method: 'POST', headers: { 'Content-Type': 'application/json', 'Content-Encoding': 'gzip' },
    body: new Uint8Array(large), signal: AbortSignal.timeout(3000),
  });
  assert.equal(response.status, 413);
  assert.equal((await response.json() as { code: number }).code, 41300);
  const unsupported = await fetch(f.base + '/login', {
    method: 'POST', headers: { 'Content-Type': 'application/json', 'Content-Encoding': 'unknown-encoding' }, body: '{}', signal: AbortSignal.timeout(3000),
  });
  assert.equal(unsupported.status, 415);
  assert.equal((await fetch(f.base + '/health')).status, 200);
});

for (const format of ['jpeg', 'png', 'webp'] as const) {
  test(`${format} upload normalizes orientation and strips metadata while keeping owner access`, async t => {
    const f = await fixture(t);
    const image = await sharp({ create: { width: 8, height: 12, channels: 3, background: '#234567' } })
      .withMetadata({ orientation: 6 }).toFormat(format).toBuffer();
    const form = new FormData();
    form.append('file', new Blob([new Uint8Array(image)]), `photo.${format}`);
    const response = await fetch(f.base + '/upload', { method: 'POST', headers: { Authorization: `Bearer ${f.tokens.resident}` }, body: form });
    const result = await response.json() as { code: number; data: { url: string } };
    assert.equal(result.code, 10000);
    const mediaPath = new URL(result.data.url).pathname;
    const media = await fetch(f.base + mediaPath, { headers: { Authorization: `Bearer ${f.tokens.resident}` } });
    assert.equal(media.status, 200);
    assert.equal(media.headers.get('content-type'), 'image/png');
    const details = await sharp(Buffer.from(await media.arrayBuffer())).metadata();
    assert.equal(details.format, 'png');
    assert.equal(details.width, 12); assert.equal(details.height, 8);
    assert.equal(details.orientation, undefined); assert.equal(details.exif, undefined);
    assert.equal((await fetch(f.base + mediaPath)).status, 401);
    assert.equal((await fetch(f.base + mediaPath, { headers: { Authorization: `Bearer ${f.tokens.other}` } })).status, 404);
  });
}

test('oversized and excessive multipart files cannot create uploaded records', async t => {
  const f = await fixture(t);
  const before = f.store.one('SELECT COUNT(*) AS n FROM uploads')!.n;
  const cases = [
    [new Uint8Array(8 * 1024 * 1024 + 1)],
    [new Uint8Array([1]), new Uint8Array([2])],
  ];
  for (const files of cases) {
    const form = new FormData();
    for (const bytes of files) form.append('file', new Blob([bytes]), 'image.png');
    const response = await fetch(f.base + '/upload', { method: 'POST', headers: { Authorization: `Bearer ${f.tokens.resident}` }, body: form, signal: AbortSignal.timeout(5000) });
    assert.equal(response.status, 413);
    assert.equal((await response.json() as { code: number }).code, 41300);
  }
  assert.equal(f.store.one('SELECT COUNT(*) AS n FROM uploads')!.n, before);
  assert.equal((await fetch(f.base + '/health')).status, 200);
});

test('PNG with a damaged IDAT checksum is rejected without saving media', async t => {
  const f = await fixture(t);
  const before = f.store.one('SELECT COUNT(*) AS n FROM uploads')!.n;
  const image = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a9X8AAAAASUVORK5CYII=', 'base64');
  const form = new FormData();
  form.append('file', new Blob([new Uint8Array(image)]), 'corrupt.png');
  const response = await fetch(f.base + '/upload', { method: 'POST', headers: { Authorization: `Bearer ${f.tokens.resident}` }, body: form });
  assert.equal((await response.json() as { code: number }).code, 40003);
  assert.equal(f.store.one('SELECT COUNT(*) AS n FROM uploads')!.n, before);
});

test('disconnecting an incomplete upload cannot crash the service or create media', async t => {
  const f = await fixture(t);
  const before = f.store.one('SELECT COUNT(*) AS n FROM uploads')!.n;
  await new Promise<void>((resolve, reject) => {
    const req = httpRequest(f.base + '/upload', { method: 'POST', headers: {
      Authorization: `Bearer ${f.tokens.resident}`, 'Content-Type': 'multipart/form-data; boundary=haven-abort',
      'Content-Length': 4096,
    } });
    req.on('error', () => resolve());
    req.setTimeout(3000, () => { req.destroy(); reject(new Error('upload teardown timed out')); });
    req.write('--haven-abort\r\nContent-Disposition: form-data; name="file"; filename="partial.png"\r\nContent-Type: image/png\r\n\r\npartial-data', () => req.destroy());
  });
  assert.equal((await fetch(f.base + '/health', { signal: AbortSignal.timeout(3000) })).status, 200);
  assert.equal(f.store.one('SELECT COUNT(*) AS n FROM uploads')!.n, before);
});
