import { createHash, randomUUID } from 'node:crypto';
import { constants, closeSync, fsyncSync, lstatSync, openSync, readFileSync, unlinkSync, writeFileSync } from 'node:fs';

export class ProcessLockOccupiedError extends Error {
  constructor() { super('锁被占用：已有进程运行或无法确认锁持有者已退出'); }
}

export function acquireProcessLock(path: string, runId = randomUUID(), recoveryDepth = 0): {
  content: string; recovered: boolean; release(): void;
} {
  if (recoveryDepth > 8) throw new ProcessLockOccupiedError();
  const content = JSON.stringify({ version: 1, runId, pid: process.pid,
    startedAt: new Date(performance.timeOrigin).toISOString() });
  let recovered = false;
  const read = () => {
    const stat = lstatSync(path);
    if (!stat.isFile() || stat.isSymbolicLink() || stat.nlink !== 1 || stat.size > 1024) throw new ProcessLockOccupiedError();
    return readFileSync(path, 'utf8');
  };
  const create = () => {
    const fd = openSync(path, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
    try { writeFileSync(fd, content); fsyncSync(fd); } finally { closeSync(fd); }
  };
  try { create(); }
  catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'EEXIST') throw error;
    let original: string;
    let pid: number;
    try {
      original = read();
      const owner = JSON.parse(original);
      if (!Number.isSafeInteger(owner.pid) || owner.pid < 1) throw new Error();
      pid = owner.pid;
    } catch { throw new ProcessLockOccupiedError(); }
    try { process.kill(pid, 0); throw new ProcessLockOccupiedError(); }
    catch (probeError) {
      // Permission errors and PID reuse are treated conservatively as a live owner.
      if ((probeError as NodeJS.ErrnoException).code !== 'ESRCH') throw new ProcessLockOccupiedError();
    }
    // Serialize reclaimers of this exact dead owner. A crashed reclaimer is
    // recovered by the same protocol; live contenders never unlink its claim.
    const digest = createHash('sha256').update(original).digest('hex').slice(0, 16);
    const claim = acquireProcessLock(`${path}.reclaim-${digest}`, runId, recoveryDepth + 1);
    try {
      if (read() !== original) throw new ProcessLockOccupiedError();
      unlinkSync(path);
      try { create(); }
      catch (claimError) {
        if ((claimError as NodeJS.ErrnoException).code === 'EEXIST') throw new ProcessLockOccupiedError();
        throw claimError;
      }
    } finally { claim.release(); }
    recovered = true;
  }
  return { content, recovered, release() {
    if (read() !== content) throw new ProcessLockOccupiedError();
    unlinkSync(path);
  } };
}
