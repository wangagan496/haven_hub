import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { existsSync, rmdirSync, unlinkSync, writeFileSync } from 'node:fs';
import { isAbsolute, join, resolve } from 'node:path';
import { z } from 'zod';
import { createPrivateDirectory } from './backup.js';
import { operationsKeyringSchema } from './operations-credentials.js';

/** Creates files in a new restricted directory; never prints or returns the secret. */
export function createOperationsKey(directory: string, expiresAt: string, now = Date.now()) {
  if (!isAbsolute(directory)) throw new Error('运行凭证目录必须是绝对路径');
  z.iso.datetime().parse(expiresAt);
  if (Date.parse(expiresAt) <= now) throw new Error('运行凭证到期时间必须在未来');
  const target = resolve(directory);
  const token = `ops_v1_${randomBytes(32).toString('hex')}`;
  const key = { id: `ops-${randomUUID()}`, sha256: createHash('sha256').update(token).digest('hex'),
    notBefore: new Date(now).toISOString(), expiresAt };
  const ring = operationsKeyringSchema.parse({ version: 1, keys: [key] });
  createPrivateDirectory(target);
  try {
    writeFileSync(join(target, 'token.json'), JSON.stringify({ token }) + '\n', { flag: 'wx', mode: 0o600 });
    writeFileSync(join(target, 'keys.json'), JSON.stringify(ring, null, 2) + '\n', { flag: 'wx', mode: 0o600 });
  } catch {
    for (const name of ['token.json', 'keys.json']) {
      const path = join(target, name);
      if (existsSync(path)) unlinkSync(path);
    }
    rmdirSync(target);
    throw new Error('运行凭证文件生成失败');
  }
  return { id: key.id, notBefore: key.notBefore, expiresAt: key.expiresAt };
}
