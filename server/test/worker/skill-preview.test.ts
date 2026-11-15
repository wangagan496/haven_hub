import test from 'node:test';
import assert from 'node:assert/strict';
import { fixture, NEXT } from '../repair/repair-fixture.js';

async function preview(f: Awaited<ReturnType<typeof fixture>>) {
  const profile = await f.call('worker', 'GET', '/worker/skills');
  const body = { workforceRevision: profile.workforceRevision, skills: ['doors'] };
  const impact = await f.call('worker', 'PUT', '/worker/skills', { ...body, preview: true });
  return { profile, body, impact };
}

test('skill preview: reassignment rejects old confirmation and reports current status without private fields', async t => {
  const f = await fixture(t);
  const row = await f.processing();
  const { profile, body, impact } = await preview(f);
  const moved = await f.change('admin', row, 'assign', { workerId: f.ids.worker2 });
  const result = await f.raw('worker', 'PUT', '/worker/skills', { ...body, previewToken: impact.previewToken });
  assert.equal(result.code, 40901);
  assert.deepEqual(await f.call('worker', 'GET', '/worker/skills'), profile);
  assert.deepEqual(result.data.returned, []);
  assert.equal(result.data.changed[0].status, moved.status);
  assert.equal(result.data.changed[0].assignmentChanged, true);
  for (const secret of [row.id, f.ids.worker2, '13800138000', 'houseInfo', 'photos']) {
    assert(!JSON.stringify(result.data).includes(secret));
  }
  const saved = await f.call('worker', 'PUT', '/worker/skills', { ...body, previewToken: result.data.previewToken });
  assert.deepEqual(saved.skills, ['doors']);
  assert.equal(f.stored(row).workerId, f.ids.worker2);
});

test('skill preview: state changes and newly affected orders invalidate the confirmation', async t => {
  const f = await fixture(t);
  let row = await f.create();
  row = await f.change('admin', row, 'assign', { workerId: f.ids.worker });
  const { body, impact } = await preview(f);
  await f.change('worker', row, 'accept');
  const changed = await f.raw('worker', 'PUT', '/worker/skills', { ...body, previewToken: impact.previewToken });
  assert.equal(changed.code, 40901);
  assert.equal(changed.data.changed[0].status, 2);
  const next = await f.processing(NEXT);
  const again = await f.raw('worker', 'PUT', '/worker/skills', { ...body, previewToken: changed.data.previewToken });
  assert.equal(again.code, 40901);
  assert.equal(again.data.returned.length, 2);
  assert.equal(f.stored(next).workerId, f.ids.worker);
  await f.call('worker', 'PUT', '/worker/skills', { ...body, previewToken: again.data.previewToken });
  assert.equal(f.stored(row).status, 1);
  assert.equal(f.stored(next).status, 1);
});

test('skill preview: unchanged confirmation succeeds and unrelated edits do not invalidate it', async t => {
  const f = await fixture(t);
  const row = await f.processing();
  const { body, impact } = await preview(f);
  await f.create('', { description: '无关的未定时工单' });
  const saved = await f.call('worker', 'PUT', '/worker/skills', { ...body, previewToken: impact.previewToken });
  assert.deepEqual(saved.skills, ['doors']);
  assert.equal(f.stored(row).status, 1);
});

test('skill preview: missing, expired, changed-input and foreign-actor tokens cannot authorize removal', async t => {
  const f = await fixture(t);
  const { profile, body, impact } = await preview(f);
  for (const input of [body, { ...body, skills: [], previewToken: impact.previewToken }]) {
    assert.equal((await f.raw('worker', 'PUT', '/worker/skills', input)).code, 40901);
  }
  const admin = await f.raw('admin', 'PUT', `/management/workers/${f.ids.worker}/skills`,
    { ...body, previewToken: impact.previewToken });
  assert.equal(admin.code, 40901);
  assert.deepEqual(admin.data.changed, []);
  f.at(f.time() + 16 * 60_000);
  assert.equal((await f.raw('worker', 'PUT', '/worker/skills', { ...body, previewToken: impact.previewToken })).code, 40901);
  assert.deepEqual(await f.call('worker', 'GET', '/worker/skills'), profile);
  const fresh = await preview(f);
  await f.call('worker', 'PUT', '/worker/skills', { ...body, previewToken: fresh.impact.previewToken });
});

test('skill preview: one operator cannot evict another operator\'s valid token', async t => {
  const f = await fixture(t);
  const a = await preview(f);
  const worker2 = await f.call('worker2', 'GET', '/worker/skills');
  const worker2Body = { workforceRevision: worker2.workforceRevision, skills: ['doors'] };
  for (let index = 0; index < 300; index++) {
    await f.call('worker2', 'PUT', '/worker/skills', { ...worker2Body, preview: true });
  }
  const saved = await f.call('worker', 'PUT', '/worker/skills', {
    ...a.body,
    previewToken: a.impact.previewToken,
  });
  assert.deepEqual(saved.skills, ['doors']);
});

test('skill preview: exceeding an operator limit evicts only that operator\'s oldest token', async t => {
  const f = await fixture(t);
  const first = await preview(f);
  const profile = await f.call('worker', 'GET', '/worker/skills');
  const body = { workforceRevision: profile.workforceRevision, skills: ['doors'] };
  for (let index = 0; index < 8; index++) {
    await f.call('worker', 'PUT', '/worker/skills', { ...body, preview: true });
  }
  const evicted = await f.raw('worker', 'PUT', '/worker/skills', {
    ...body,
    previewToken: first.impact.previewToken,
  });
  assert.equal(evicted.code, 40901);
  assert.ok(evicted.data.previewToken);
  const saved = await f.call('worker', 'PUT', '/worker/skills', {
    ...body,
    previewToken: evicted.data.previewToken,
  });
  assert.deepEqual(saved.skills, ['doors']);
});
