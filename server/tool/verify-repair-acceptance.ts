import assert from 'node:assert/strict';
import { readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import sharp from 'sharp';

const base = 'http://127.0.0.1:3010';
const directory = resolve('../output/repair-fixtures-20261015');
const report = JSON.parse(readFileSync(resolve(directory, 'seed-report.json'), 'utf8')) as any;
async function request(path: string, token = '', body?: unknown) {
  const response = await fetch(`${base}${path}`, { method: body ? 'POST' : 'GET',
    headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), 'Content-Type': 'application/json' },
    ...(body ? { body: JSON.stringify(body) } : {}) });
  const envelope = await response.json() as any;
  assert.equal(response.status, 200, path);
  assert.equal(envelope.code, 10000, `${path}: ${envelope.message}`);
  return envelope.data;
}
async function login(mobile: string) {
  const code = await request(`/code?mobile=${mobile}`);
  assert(code.development && code.code, 'Expected local development verification code');
  const login = await request('/login', '', { mobile, code: code.code });
  assert(login.token, 'Expected access token');
  return login.token as string;
}
const resident = await login('19900000001');
const repairs = await request('/repair?pageSize=100', resident);
const rows = repairs.rows as any[];
assert.equal(rows.length, 18);
const counts: Record<string, number> = {};
for (const status of [1, 5, 2, 3]) counts[status] = rows.filter(row => row.status === status).length;
assert.deepEqual(counts, { 1: 3, 2: 5, 3: 5, 5: 5 });
const rooms = await request('/room', resident) as any[];
assert.equal(rooms.length, 3);
assert(rooms.every(room => !room.point.includes('演示')));
const urls = [...new Set<string>(rows.flatMap(row => row.attachment))];
const media = [];
for (const url of urls) {
  const response = await fetch(url);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('content-type')?.split(';')[0], 'image/jpeg');
  const bytes = Buffer.from(await response.arrayBuffer());
  const metadata = await sharp(bytes).metadata();
  assert(metadata.width! >= 320 && metadata.height! >= 240);
  media.push({ url, bytes: bytes.length, width: metadata.width, height: metadata.height });
}
const admin = await login('19900000002');
const adminRows = await request('/management/repairs', admin) as any[];
assert.equal(adminRows.filter(row => row._fixtureBatch === report.batch).length, 12);
assert.equal(adminRows.filter(row => row._fixtureBatch === report.batch || row._fixtureBatch === 'worker-variety-20261015').length, 18);
const workers = await request('/management/workers', admin) as any[];
assert.equal(workers.length, 3);
const workerChecks = [];
for (const mobile of ['19900000003', '19900000004', '19900000005']) {
  const token = await login(mobile);
  const list = await request('/worker/repairs', token) as any[];
  const perStatus = mobile === '19900000003' ? 3 : 1;
  assert.equal(list.length, perStatus * 3);
  for (const status of [2, 3, 5]) {
    const matching = list.filter(row => row.status === status);
    assert.equal(matching.length, perStatus);
    assert.equal(new Set(matching.map(row => row.description)).size, perStatus);
    assert.equal(new Set(matching.map(row => row.houseInfo)).size, perStatus);
  }
  assert.equal(new Set(list.map(row => row.id)).size, list.length);
  assert(list.every(row => row.workerMobile === mobile));
  workerChecks.push({ mobile, count: list.length, perStatus, states: [2, 3, 5] });
}
const result = { checkedAt: new Date().toISOString(), residentRecords: rows.length,
  roomCount: rooms.length, counts, photos: media, adminCount: adminRows.length, workers: workerChecks };
writeFileSync(resolve(directory, 'verification.json'), JSON.stringify(result, null, 2));
console.log(JSON.stringify({ residentRecords: rows.length, roomCount: rooms.length, counts,
  imagesDecoded: media.length, adminCount: adminRows.length, workerChecks }));
