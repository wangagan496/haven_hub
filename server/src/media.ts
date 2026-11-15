import type { DatabaseSync } from 'node:sqlite';
import type { Collection, RecordData, Store } from './database.js';
import { ApiError, requireValue } from './errors.js';

export type MediaPurpose = 'identity' | 'repair' | 'visitor' | 'avatar';

/** 共享上传归属校验，住房、报修和头像均复用，不依赖社区业务服务。 */
export function ownedUpload(store: Store, publicBaseUrl: string, userId: string, url: string, purpose?: MediaPurpose) {
  const prefix = `${publicBaseUrl}/media/`;
  requireValue(url.startsWith(prefix), '图片必须先上传到当前服务');
  const upload = store.one('SELECT id FROM uploads WHERE id = ? AND userId = ?', url.slice(prefix.length), userId);
  requireValue(upload, '图片不存在或不属于当前账号');
  if (purpose) requireMediaPurpose(store, String(upload.id), purpose);
}

export function mediaId(value: unknown): string | undefined {
  if (typeof value !== 'string') return undefined;
  try {
    const url = new URL(value);
    if (!['http:', 'https:'].includes(url.protocol) || url.search || url.hash || url.username || url.password) return undefined;
    return /^\/media\/([a-f\d]{64})$/.exec(url.pathname)?.[1];
  } catch { return undefined; }
}

function recordImages(table: Collection, record: RecordData): { purpose: MediaPurpose; urls: unknown[] } {
  if (table === 'rooms') return { purpose: 'identity', urls: [record.idcardFrontUrl, record.idcardBackUrl] };
  if (table === 'repairs') return { purpose: 'repair', urls: Array.isArray(record.attachment) ? record.attachment : [] };
  return { purpose: 'visitor', urls: [record.url] };
}

/** Keep historical purpose bindings: deleting a room must not make an ID photo shareable. */
export function bindMedia(db: DatabaseSync, owner: string, purpose: MediaPurpose, recordId: string, urls: unknown[]) {
  for (const url of urls) {
    const id = mediaId(url);
    if (id) db.prepare(`INSERT OR IGNORE INTO upload_bindings(imageId,purpose,recordId)
      SELECT id,?,? FROM uploads WHERE id=? AND userId=?`).run(purpose, recordId, id, owner);
  }
}

export function bindRecordMedia(db: DatabaseSync, table: Collection, owner: string, record: RecordData) {
  const { purpose, urls } = recordImages(table, record);
  bindMedia(db, owner, purpose, record.id, urls);
}

export function requireMediaPurpose(store: Store, id: string, purpose: MediaPurpose) {
  const conflict = store.one('SELECT 1 FROM upload_bindings WHERE imageId=? AND purpose<>? LIMIT 1', id, purpose);
  requireValue(!conflict, '图片已用于其他用途，请重新上传，证件照片不能用作报修图片或头像');
}

/** Authorization is evaluated against the current object, never the historical assignment. */
export function readMedia(store: Store, userId: string, id: string) {
  const denied = () => new ApiError(404, 40400, '图片不存在或无权访问');
  if (!/^[a-f\d]{64}$/.test(id)) throw denied();
  const image = store.one('SELECT userId,mime,bytes FROM uploads WHERE id=?', id);
  if (!image) throw denied();
  if (image.userId === userId) return image;
  const role = store.one('SELECT role FROM users WHERE id=?', userId)?.role;
  const bindings = store.db.prepare('SELECT purpose,recordId FROM upload_bindings WHERE imageId=?').all(id);
  const sensitive = bindings.some(binding => binding.purpose === 'identity');
  for (const binding of bindings) {
    if (sensitive && binding.purpose !== 'identity') continue;
    const table = binding.purpose === 'identity' ? 'rooms' : binding.purpose === 'repair' ? 'repairs' : undefined;
    if (!table || (role !== 'admin' && !(table === 'repairs' && role === 'worker'))) continue;
    const row = store.one(`SELECT userId,payload FROM ${table} WHERE id=?`, String(binding.recordId));
    if (!row || row.userId !== image.userId) continue;
    let record: RecordData;
    try { record = JSON.parse(String(row.payload)) as RecordData; }
    catch { continue; }
    if (!record || !recordImages(table, record).urls.some(url => mediaId(url) === id)) continue;
    if (role === 'admin' || (role === 'worker' && record.workerId === userId)) return image;
  }
  throw denied();
}
