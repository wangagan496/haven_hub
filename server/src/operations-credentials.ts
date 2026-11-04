import { createHash, timingSafeEqual } from 'node:crypto';
import { closeSync, fstatSync, openSync, readSync } from 'node:fs';
import { z } from 'zod';
import type { RequestHandler } from 'express';

export const operationsTokenPattern = /^ops_v1_[a-f0-9]{64}$/;
export const operationsKeyringSchema = z.object({
  version: z.literal(1),
  keys: z.array(z.object({
    id: z.string().regex(/^[A-Za-z0-9_-]{1,64}$/),
    sha256: z.string().regex(/^[a-f0-9]{64}$/),
    notBefore: z.iso.datetime(), expiresAt: z.iso.datetime(),
  }).strict().refine(key => Date.parse(key.expiresAt) > Date.parse(key.notBefore))).max(2),
}).strict().refine(ring => new Set(ring.keys.map(key => key.id)).size === ring.keys.length
  && new Set(ring.keys.map(key => key.sha256)).size === ring.keys.length);

/** Shared bounded reader for operational configuration, never includes input in errors. */
export function readOperationsJson(path: string, maxBytes: number): unknown {
  const fd = openSync(path, 'r');
  try {
    const stat = fstatSync(fd);
    if (!stat.isFile() || stat.size > maxBytes) throw new Error('Invalid local file');
    const bytes = Buffer.alloc(maxBytes + 1);
    let size = 0;
    while (size <= maxBytes) {
      const read = readSync(fd, bytes, size, bytes.length - size, null);
      if (!read) break;
      size += read;
    }
    if (size > maxBytes) throw new Error('Local file too large');
    return JSON.parse(bytes.subarray(0, size).toString('utf8'));
  } finally { closeSync(fd); }
}

export function readOperationsKeyring(path: string) {
  try { return operationsKeyringSchema.parse(readOperationsJson(path, 4096)); }
  catch { throw new Error('OPERATIONS_KEYS_FILE 无法读取或格式不正确'); }
}

/** Only mounted on the read-only machine snapshot, never on user/business routes. */
export function operationsKeyAuthentication(path: string, now: () => number): RequestHandler {
  return (req, res, next) => {
    if (req.method !== 'GET') {
      res.setHeader('Allow', 'GET');
      res.status(405).json({ code: 40500, message: '运行指标仅支持读取', data: null });
      return;
    }
    // Machine protocol evolves separately from the mobile application's minimum version.
    if (req.get('X-Operations-Version') !== '1') {
      res.status(426).json({ code: 42600, message: '运行检查协议版本不受支持', data: null });
      return;
    }
    const headers = req.rawHeaders.filter((_value, index) => index % 2 === 0);
    const authorization = req.get('authorization') ?? '';
    if (headers.filter(name => name.toLowerCase() === 'authorization').length !== 1
      || !/^Bearer ops_v1_[a-f0-9]{64}$/.test(authorization)) {
      res.status(401).json({ code: 40100, message: '运行检查凭证无效或已过期', data: null });
      return;
    }
    let ring: ReturnType<typeof readOperationsKeyring>;
    try { ring = readOperationsKeyring(path); }
    catch {
      // No cached last-good keyring: a broken/removed file must revoke access, not preserve it.
      res.status(503).json({ code: 50300, message: '运行检查凭证配置不可用', data: null });
      return;
    }
    const digest = createHash('sha256').update(authorization.slice(7)).digest();
    const at = now();
    let accepted = false;
    for (const key of ring.keys) {
      const matches = timingSafeEqual(digest, Buffer.from(key.sha256, 'hex'));
      if (matches && at >= Date.parse(key.notBefore) && at < Date.parse(key.expiresAt)) accepted = true;
    }
    if (!accepted) {
      res.status(401).json({ code: 40100, message: '运行检查凭证无效或已过期', data: null });
      return;
    }
    next();
  };
}
