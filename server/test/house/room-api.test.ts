import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { HousingService } from '../../src/housing/service.js';
import { fixture } from '../helpers/api-fixture.js';

test('optional floors round trip through HTTP and invalid floors explain the error', async t => {
  const f = await fixture(t);
  const session = await f.login();
  const url = await f.upload(session.token);
  const body = f.roomBody(url);
  const created = await f.request('POST', '/room', session.token, { ...body, floor: '63' });
  assert.equal(created.code, 10000);
  const id = created.data.rows[0].id;
  assert.equal((await f.request('GET', `/room/${id}`, session.token)).data.floor, '63');
  const repair = await f.request('POST', '/repair', session.token, {
    houseId: id, repairItemId: '1004', mobile: '13800138000',
  });
  assert.equal(repair.code, 10000);
  assert.equal(repair.data.rows[0].houseInfo, '学习小区 1栋 63层 101');
  const visitor = await f.request('POST', '/visitor', session.token, {
    houseId: id, name: '访客', gender: 1, mobile: '13800138000', visitDate: '2026-10-20',
  });
  assert.equal(visitor.code, 10000);
  assert.equal(visitor.data.rows[0].houseInfo, '学习小区 1栋 63层 101');
  let revision = created.data.rows[0].revision;
  for (const floor of ['100', 'B1', '']) {
    const edited = await f.request('POST', '/room', session.token, { ...body, id, revision, floor });
    assert.equal(edited.code, 10000);
    revision = edited.data.rows[0].revision;
    assert.equal(edited.data.rows[0].floor, floor);
    assert.equal((await f.request('GET', '/room', session.token)).data[0].floor, floor);
  }
  for (const floor of ['0', 'abc', 'B0', '-1', '10000']) {
    const invalid = await f.request('POST', '/room', session.token, { ...body, id, revision, floor });
    assert.equal(invalid.code, 40000);
    assert.equal(invalid.message, '请输入有效楼层，例如33、100或B1');
    assert.equal((await f.request('GET', `/room/${id}`, session.token)).data.floor, '');
  }
  const legacy = await f.request('POST', '/room', session.token, body);
  assert.equal(legacy.code, 10000, 'older clients may omit floor');
});

test('room accepts English owner names through the HTTP API', async t => {
  const f = await fixture(t);
  const session = await f.login();
  const url = await f.upload(session.token);
  for (const name of ['John Smith', "O'Neil", 'Anne-Marie']) {
    const response = await f.request('POST', '/room', session.token, {
      ...f.roomBody(url), name,
    });
    assert.equal(response.code, 10000);
    assert(response.data.rows.some((row: { name: string }) => row.name === name));
  }
});

test('English owner names are unique across accounts; Chinese names may repeat', async t => {
  const f = await fixture(t);
  const a = await f.login();
  const b = await f.login('13800138001');
  const aUrl = await f.upload(a.token);
  const bUrl = await f.upload(b.token);
  const aBody = { ...f.roomBody(aUrl), name: 'John  Smith' };
  const bBody = { ...f.roomBody(bUrl), name: ' john smith ' };

  const first = await f.request('POST', '/room', a.token, aBody);
  assert.equal(first.code, 10000);
  const firstId = first.data.rows[0].id;
  const duplicate = await f.request('POST', '/room', b.token, bBody);
  assert.equal(duplicate.code, 40002);
  assert.equal(duplicate.message, '该英文姓名已被登记，请更换姓名');
  assert.deepEqual((await f.request('GET', '/room', b.token)).data, []);

  const edited = await f.request('POST', '/room', a.token, { ...aBody, id: firstId, revision: first.data.rows[0].revision, room: '102' });
  assert.equal(edited.code, 10000, 'editing a record must not conflict with itself');

  const chineseA = await f.request('POST', '/room', a.token, { ...aBody, name: '张三' });
  const chineseB = await f.request('POST', '/room', b.token, { ...bBody, name: '张三' });
  assert.equal(chineseA.code, 10000);
  assert.equal(chineseB.code, 10000);

  const mixedA = await f.request('POST', '/room', a.token, { ...aBody, name: '李John' });
  const mixedB = await f.request('POST', '/room', b.token, { ...bBody, name: '李john' });
  assert.equal(mixedA.code, 10000);
  assert.equal(mixedB.code, 40002, 'names containing Latin letters use the English rule');

  assert.equal((await f.request('DELETE', `/room/${firstId}`, a.token,
    { revision: edited.data.rows.find((row: { id: string }) => row.id === firstId).revision })).code, 10000);
  const reused = await f.request('POST', '/room', b.token, bBody);
  assert.equal(reused.code, 10000, 'deleting a record releases its English name');
});

test('validation errors identify the invalid house field', async t => {
  const f = await fixture(t);
  const session = await f.login();
  const missingCommunity = await f.request('POST', '/room', session.token, {
    point: '', building: '1栋', room: '101', name: '张三', gender: 1,
    mobile: '13800138000', idcardFrontUrl: 'bad', idcardBackUrl: 'bad',
  });
  assert.equal(missingCommunity.message, '小区不能为空');

  const invalidPhoto = await f.request('POST', '/room', session.token, {
    point: '学习小区', building: '1栋', room: '101', name: '张三', gender: 1,
    mobile: '13800138000', idcardFrontUrl: 'bad', idcardBackUrl: 'bad',
  });
  assert.equal(invalidPhoto.message, '身份证正面照片无效，请重新上传');
});

test('room writes return full authoritative lists, enforce ownership and preserve restart data', async t => {
  const directory = mkdtempSync(join(tmpdir(), 'haven-server-test-'));
  // 单个已知临时目录；清理安排在服务关闭之后。
  const f = await fixture(t, join(directory, 'test.sqlite'));
  const a = await f.login();
  const b = await f.login('13800138001');
  const { record, body } = await f.room(a.token);
  const edited = await f.request('POST', '/room', a.token, { ...body, id: record.id, revision: record.revision, room: '102' });
  assert.equal(edited.data.rows[0].room, '102');
  assert.equal(edited.data.total, 1);
  assert.equal((await f.request('GET', `/room/${record.id}`, b.token)).status, 404);
  assert.equal((await f.request('POST', '/room', b.token, { ...body, id: record.id })).status, 404);
  assert.equal((await f.request('DELETE', `/room/${record.id}`, b.token)).status, 404);
  assert.notEqual((await f.request('POST', '/room', b.token, body)).code, 10000, 'another account cannot bind the uploaded image');
  assert.deepEqual((await f.request('GET', '/room', b.token)).data, []);
  await f.close();
  const reopened = await fixture(t, join(directory, 'test.sqlite'));
  const persisted = await reopened.request('GET', '/room', a.token);
  assert.equal(persisted.data[0].room, '102');
  const deleted = await reopened.request('DELETE', `/room/${record.id}`, a.token, { revision: persisted.data[0].revision });
  assert.deepEqual(deleted.data, { complete: true, rows: [], total: 0 });
  await reopened.close();
  rmSync(directory, { recursive: true });
});

test('mutation rolls back if constructing the returned full list fails', async t => {
  const f = await fixture(t);
  const a = await f.login();
  const profile = await f.request('GET', '/userInfo', a.token);
  const { body } = await f.room(a.token);
  const service = new HousingService(f.store, f.config.publicBaseUrl);
  const list = f.store.list.bind(f.store);
  f.store.list = () => { throw new Error('injected read failure'); };
  assert.throws(() => service.save(profile.data.id, body), /injected read failure/);
  f.store.list = list;
  assert.equal((await f.request('GET', '/room', a.token)).data.length, 1);
});
