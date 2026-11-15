import test, { type TestContext } from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes, randomUUID } from 'node:crypto';
import { Store } from '../../src/database.js';
import { ApiError } from '../../src/errors.js';
import { readMedia } from '../../src/media.js';
import { HousingService } from '../../src/housing/service.js';

// 直接组合住房模块和真实内存 SQLite；不启动 Express、CommunityService 或 WorkflowService。
function fixture(t: TestContext) {
  const store = new Store(':memory:');
  t.after(() => store.close());
  const resident = randomUUID(), other = randomUUID(), admin = randomUUID();
  for (const [id, mobile, role] of [
    [resident, '13800138000', 'resident'],
    [other, '13800138001', 'resident'],
    [admin, '13800138090', 'admin'],
  ]) {
    store.run('INSERT INTO users(id,mobile,nickName,role) VALUES (?,?,?,?)', id!, mobile!, '测试账号', role!);
  }
  const baseUrl = 'https://housing.invalid';
  const now = () => Date.parse('2026-11-05T00:00:00Z');
  const service = new HousingService(store, baseUrl, now);
  const photo = (owner: string) => {
    const id = randomBytes(32).toString('hex');
    store.run('INSERT INTO uploads(id,userId,mime,bytes) VALUES (?,?,?,?)', id, owner, 'image/png', Buffer.from([1, 2, 3]));
    return { id, url: `${baseUrl}/media/${id}` };
  };
  const image = photo(resident);
  const body = {
    point: '测试小区', building: '1栋', room: '101', floor: '3', name: '张三',
    gender: 1, mobile: '13800138000', idcardFrontUrl: image.url, idcardBackUrl: image.url,
  };
  return { store, service, resident, other, admin, body, image, photo, baseUrl, now };
}

const code = (expected: number) => (error: unknown) => error instanceof ApiError && error.code === expected;

test('housing module: registration review resubmission and deletion share one lifecycle', t => {
  const f = fixture(t);
  const submissionId = randomUUID();
  const created = f.service.save(f.resident, { ...f.body, submissionId });
  assert.equal(created.complete, true);
  assert.equal(created.total, 1);
  const id = created.createdId!;
  assert.equal(f.service.detail(f.resident, id).revision, 1);
  assert.equal(f.service.reviewQueue(f.admin)[0]!.id, id);
  const rejected = f.service.review(id, f.admin, { revision: 1, decision: 'reject', reason: '照片不清楚' });
  assert.equal(rejected.status, 3);
  assert.equal(rejected.revision, 2);
  assert.equal(rejected.reviewedBy, f.admin);
  assert.throws(() => f.service.save(f.resident, { ...f.body, id, revision: 1 }), code(40900));
  const edited = f.service.save(f.resident, { ...f.body, id, revision: 2, room: '102' });
  assert.equal(edited.rows[0]!.status, 1);
  assert.equal(edited.rows[0]!.reviewReason, '');
  const approved = f.service.review(id, f.admin, { revision: 3, decision: 'approve' });
  assert.equal(approved.status, 2);
  assert.equal(approved.revision, 4);
  assert.equal(Number(f.store.one('SELECT COUNT(*) AS n FROM management_audit WHERE targetId=?', id)!.n), 2);
  assert.equal(readMedia(f.store, f.admin, f.image.id).userId, f.resident);
  assert.deepEqual(f.service.remove(f.resident, id, { revision: 4 }), { complete: true, rows: [], total: 0 });
  assert.deepEqual(f.service.submissionResult(f.resident, submissionId), { state: 'deleted', createdId: id });
  assert.throws(() => f.service.save(f.resident, { ...f.body, submissionId }), code(40904));
  assert.throws(() => readMedia(f.store, f.admin, f.image.id), code(40400));
  assert.equal(Number(f.store.one('SELECT COUNT(*) AS n FROM upload_bindings WHERE imageId=?', f.image.id)!.n), 1);
});

test('housing module: direct callers cannot bypass ownership or reviewer authorization', t => {
  const f = fixture(t);
  const id = f.service.save(f.resident, f.body).createdId!;
  assert.deepEqual(f.service.list(f.other), []);
  assert.throws(() => f.service.detail(f.other, id), code(40400));
  assert.throws(() => f.service.save(f.other, { ...f.body, id }), code(40400));
  assert.throws(() => f.service.remove(f.other, id, undefined), code(40400));
  assert.throws(() => f.service.reviewQueue(f.resident), code(40300));
  assert.throws(() => f.service.review('unknown-house', f.resident, { invalid: true }), code(40300));
  assert.equal(f.service.detail(f.resident, id).revision, 1);
  assert.equal(Number(f.store.one('SELECT COUNT(*) AS n FROM management_audit')!.n), 0);
});

test('housing module: independent instances share durable account-scoped receipts and stop fencing', t => {
  const f = fixture(t);
  const second = new HousingService(f.store, f.baseUrl, f.now);
  const submissionId = randomUUID();
  const input = { ...f.body, submissionId };
  const created = f.service.save(f.resident, input);
  assert.equal(second.save(f.resident, input).createdId, created.createdId);
  assert.equal(second.list(f.resident).length, 1);
  assert.throws(() => second.save(f.resident, { ...input, room: '102' }), code(40902));
  assert.deepEqual(second.closeSubmission(f.resident, submissionId), { state: 'created', createdId: created.createdId });
  assert.deepEqual(second.submissionResult(f.other, submissionId), { state: 'unknown', createdId: '' });
  const stoppedId = randomUUID();
  assert.deepEqual(second.closeSubmission(f.resident, stoppedId), { state: 'closed', createdId: '' });
  assert.throws(() => f.service.save(f.resident, { ...f.body, submissionId: stoppedId }), code(40903));
  const image = f.photo(f.other);
  const otherCreated = second.save(f.other, { ...input, mobile: '13800138001', idcardFrontUrl: image.url, idcardBackUrl: image.url });
  assert.notEqual(otherCreated.createdId, created.createdId);
  assert.equal(otherCreated.total, 1);
});

test('housing module: audit and authoritative response failures roll back the entire operation', t => {
  const f = fixture(t);
  const id = f.service.save(f.resident, f.body).createdId!;
  const before = f.service.detail(f.resident, id);
  const run = f.store.run.bind(f.store);
  f.store.run = (sql, ...values) => {
    if (sql.startsWith('INSERT INTO management_audit')) throw new Error('audit unavailable');
    return run(sql, ...values);
  };
  assert.throws(() => f.service.review(id, f.admin, { revision: 1, decision: 'approve' }), /audit unavailable/);
  f.store.run = run;
  assert.deepEqual(f.service.detail(f.resident, id), before);
  assert.equal(f.service.review(id, f.admin, { revision: 1, decision: 'approve' }).revision, 2);

  const image = f.photo(f.resident);
  const submissionId = randomUUID();
  const list = f.service.list.bind(f.service);
  f.service.list = () => { throw new Error('response unavailable'); };
  assert.throws(() => f.service.save(f.resident, { ...f.body, submissionId, idcardFrontUrl: image.url, idcardBackUrl: image.url }), /response unavailable/);
  f.service.list = list;
  assert.equal(f.service.list(f.resident).length, 1);
  assert.deepEqual(f.service.submissionResult(f.resident, submissionId), { state: 'unknown', createdId: '' });
  assert.equal(Number(f.store.one('SELECT COUNT(*) AS n FROM upload_bindings WHERE imageId=?', image.id)!.n), 0);
});
