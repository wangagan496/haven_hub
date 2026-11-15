import test from 'node:test';
import assert from 'node:assert/strict';
import fs, { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { syncBuiltinESMExports } from 'node:module';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { acquireProcessLock } from '../../src/process-lock.js';

function fixture(t: test.TestContext) {
  const root = mkdtempSync(join(tmpdir(), 'haven-process-lock-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const child = spawnSync(process.execPath, ['-e', 'process.stdout.write(JSON.stringify({pid:process.pid,startedAt:new Date(performance.timeOrigin).toISOString()}))'], { encoding: 'utf8', windowsHide: true });
  assert.equal(child.status, 0);
  return { path: join(root, 'writer.lock'), dead: child.stdout };
}

test('locks record process identity and never steal a live owner', t => {
  const { path } = fixture(t), lock = acquireProcessLock(path);
  const owner = JSON.parse(readFileSync(path, 'utf8'));
  assert.equal(owner.pid, process.pid);
  assert.equal(owner.startedAt, new Date(performance.timeOrigin).toISOString());
  assert.throws(() => acquireProcessLock(path), /锁被占用/);
  lock.release();
  assert(!existsSync(path));
});

test('a dead owner and an interrupted stale-lock reclaimer can both be recovered', t => {
  const { path, dead } = fixture(t);
  writeFileSync(path, dead);
  const claim = `${path}.reclaim-${createHash('sha256').update(dead).digest('hex').slice(0, 16)}`;
  writeFileSync(claim, dead);
  const lock = acquireProcessLock(path);
  assert.equal(lock.recovered, true);
  assert(!existsSync(claim));
  lock.release();
});

test('competing reclaimers cannot remove a replacement owner during stale-lock takeover', t => {
  const { path, dead } = fixture(t);
  writeFileSync(path, dead);
  const unlink = fs.unlinkSync;
  let competed = false;
  const observer = t.mock.method(fs, 'unlinkSync', (target: fs.PathLike) => {
    if (String(target) === path && !competed) {
      competed = true;
      assert.throws(() => acquireProcessLock(path), /锁被占用/);
    }
    unlink(target);
  });
  syncBuiltinESMExports();
  try {
    const lock = acquireProcessLock(path);
    assert.equal(readFileSync(path, 'utf8'), lock.content);
    assert.equal(competed, true);
    lock.release();
  } finally { observer.mock.restore(); syncBuiltinESMExports(); }
});
