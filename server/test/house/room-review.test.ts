import test from 'node:test';
import assert from 'node:assert/strict';
import { fixture } from '../helpers/api-fixture.js';

test('property review: review and resubmission increment revision; stale and unauthorized reviews rejected', async t => {
  const f = await fixture(t);
  const resident = await f.login();
  const admin = await f.login('13800138090');
  f.store.run("UPDATE users SET role = 'admin' WHERE mobile = ?", '13800138090');
  const house = await f.room(resident.token);
  const path = `/management/rooms/${house.record.id}/review`;
  assert.equal((await f.request('GET','/management/rooms',resident.token)).status,403);
  assert.equal((await f.request('PUT',path,resident.token,{revision:1,decision:'approve'})).status,403);
  assert.notEqual((await f.request('PUT',path,admin.token,{revision:1,decision:'reject',reason:''})).code,10000);
  const rejected = await f.request('PUT',path,admin.token,{revision:1,decision:'reject',reason:'证件照片不清楚'});
  assert.equal(rejected.data.status,3);
  assert.equal(rejected.data.revision,2);
  const reviewAfterRejection = await f.request('PUT',path,admin.token,{revision:2,decision:'approve'});
  assert.equal(reviewAfterRejection.status,409);
  assert.equal(reviewAfterRejection.code,40900);
  assert.deepEqual((await f.request('GET',`/room/${house.record.id}`,resident.token)).data,rejected.data);
  assert.equal((await f.request('GET',`/room/${house.record.id}`,resident.token)).data.reviewReason,'证件照片不清楚');
  const edited = await f.request('POST','/room',resident.token,{...house.body,id:house.record.id,revision:rejected.data.revision});
  assert.equal(edited.data.rows[0].status,1);
  assert.equal(edited.data.rows[0].revision,3);
  assert.equal(edited.data.rows[0].reviewReason,'');
  assert.equal(edited.data.rows[0].id,house.record.id);
  assert.equal((await f.request('PUT',path,admin.token,{revision:1,decision:'approve'})).status,409);
  const approved = await f.request('PUT',path,admin.token,{revision:3,decision:'approve'});
  assert.equal(approved.data.status,2);
  assert.equal(approved.data.revision,4);
  const reviewAfterApproval = await f.request('PUT',path,admin.token,{revision:4,decision:'reject',reason:'重复审核'});
  assert.equal(reviewAfterApproval.status,409);
  assert.equal(reviewAfterApproval.code,40900);
  assert.deepEqual((await f.request('GET',`/room/${house.record.id}`,resident.token)).data,approved.data);
});

test('property review: concurrent reviewers cannot overwrite the first result even with the same revision', async t => {
  const f = await fixture(t);
  const resident = await f.login();
  const firstAdmin = await f.login('13800138090');
  const secondAdmin = await f.login('13800138091');
  f.store.run("UPDATE users SET role = 'admin' WHERE mobile IN (?, ?)", '13800138090', '13800138091');
  const house = await f.room(resident.token);
  const path = `/management/rooms/${house.record.id}/review`;
  const results = await Promise.all([
    f.request('PUT',path,firstAdmin.token,{revision:1,decision:'approve'}),
    f.request('PUT',path,secondAdmin.token,{revision:1,decision:'reject',reason:'证件照片不清楚'}),
  ]);
  assert.deepEqual(results.map(result => result.status).sort(),[200,409]);
  const successfulReview = results.find(result => result.code === 10000)!;
  const conflictingReview = results.find(result => result.status === 409)!;
  assert.equal(conflictingReview.code,40900);
  assert.equal(conflictingReview.message,'记录已更新，请刷新后再操作');
  assert.equal(successfulReview.data.revision,2);
  const savedHouse = await f.request('GET',`/room/${house.record.id}`,resident.token);
  assert.deepEqual(savedHouse.data,successfulReview.data);
});
