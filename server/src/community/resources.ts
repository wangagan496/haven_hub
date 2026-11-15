import { z } from 'zod';
import type { RecordData } from '../database.js';

export const date = z.string().regex(/^\d{4}-\d{2}-\d{2}$/).refine(value => {
  const timestamp = Date.parse(`${value}T00:00:00Z`);
  return Number.isFinite(timestamp) && new Date(timestamp).toISOString().slice(0, 10) === value;
}, '日期无效');

export function houseInfo(house: RecordData) {
  const floor = typeof house.floor === 'string' && house.floor
    ? (house.floor.startsWith('B') ? `地下${house.floor.slice(1)}层` : `${house.floor}层`) : '';
  return [house.point, house.building, floor, house.room].filter(Boolean).join(' ');
}
