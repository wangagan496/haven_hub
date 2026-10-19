import { z } from 'zod';
import type { RecordData, Store } from '../database.js';
import { requireValue } from '../errors.js';

export const date = z.string().regex(/^\d{4}-\d{2}-\d{2}$/).refine(value => {
  const timestamp = Date.parse(`${value}T00:00:00Z`);
  return Number.isFinite(timestamp) && new Date(timestamp).toISOString().slice(0, 10) === value;
}, '日期无效');

export function houseInfo(house: RecordData) {
  const floor = typeof house.floor === 'string' && house.floor
    ? (house.floor.startsWith('B') ? `地下${house.floor.slice(1)}层` : `${house.floor}层`) : '';
  return [house.point, house.building, floor, house.room].filter(Boolean).join(' ');
}

export function ownedUpload(store: Store, publicBaseUrl: string, userId: string, url: string) {
  const prefix = `${publicBaseUrl}/media/`;
  requireValue(url.startsWith(prefix), '图片必须先上传到当前服务');
  const upload = store.one('SELECT id FROM uploads WHERE id = ? AND userId = ?', url.slice(prefix.length), userId);
  requireValue(upload, '图片不存在或不属于当前账号');
}
